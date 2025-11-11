import { expect } from "chai";
import { ethers } from "hardhat";
import { SYSTEM } from "../../../constants";
import { time } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Complete E2E Test Suite for Slashing System
 *
 * Covers:
 * - Whistleblower reward distribution
 * - Governance fund management (burn/treasury)
 * - Rate limiting across multiple blocks
 * - Multi-validator slashing scenarios
 * - Edge cases and security validations
 */
describe("Slashing Complete E2E Tests", function () {
  let slashing: any;
  let inspector: any;
  let hydraStaking: any;
  let owner: any;
  let governance: any;
  let treasury: any;
  let systemSigner: any;
  let validator1: any;
  let validator2: any;
  let validator3: any;
  let reporter: any;

  // Wallets with known private keys for raw signing
  let validator1Wallet: any;
  let validator2Wallet: any;
  let validator3Wallet: any;

  const LOCK_PERIOD = 30 * 24 * 60 * 60; // 30 days in seconds

  // Helper to sign raw hash (matching Go's ECDSA signing)
  async function signRawHash(wallet: any, data: string): Promise<string> {
    const dataBytes = ethers.utils.arrayify(data);
    const hash = ethers.utils.keccak256(dataBytes);
    const signature = wallet._signingKey().signDigest(hash);
    return ethers.utils.joinSignature(signature);
  }

  beforeEach(async function () {
    [owner, governance, treasury, validator1, validator2, validator3, reporter] =
      await ethers.getSigners();

    // Create Wallet objects with known private keys
    validator1Wallet = new ethers.Wallet("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
    validator2Wallet = new ethers.Wallet("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6");
    validator3Wallet = new ethers.Wallet("0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a");

    // Deploy BLS contract
    const BLSFactory = await ethers.getContractFactory("BLS");
    const bls = await BLSFactory.deploy();
    await bls.deployed();

    // Deploy HydraChain (Inspector)
    const InspectorFactory = await ethers.getContractFactory("HydraChain");
    inspector = await InspectorFactory.deploy();
    await inspector.deployed();

    // Deploy HydraStaking
    const HydraStakingFactory = await ethers.getContractFactory("HydraStaking");
    hydraStaking = await HydraStakingFactory.deploy();
    await hydraStaking.deployed();

    // Fund SYSTEM account
    await owner.sendTransaction({
      to: SYSTEM,
      value: ethers.utils.parseEther("100"),
    });

    // Impersonate SYSTEM
    await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
    systemSigner = await ethers.getSigner(SYSTEM);

    // Initialize HydraChain with validators
    const validatorInit = [
      {
        addr: validator1.address,
        pubkey: [1, 0, 0, 0],
        signature: [0, 0],
      },
      {
        addr: validator2.address,
        pubkey: [2, 0, 0, 0],
        signature: [0, 0],
      },
      {
        addr: validator3.address,
        pubkey: [3, 0, 0, 0],
        signature: [0, 0],
      },
    ];

    await inspector.connect(systemSigner).initialize(
      validatorInit,
      governance.address, // governance
      hydraStaking.address, // hydraStakingAddr
      owner.address, // hydraDelegationAddr
      owner.address, // rewardWalletAddr
      owner.address, // daoIncentiveVaultAddr
      bls.address
    );

    // Initialize HydraStaking
    await hydraStaking.connect(systemSigner).initialize(
      owner.address, // newHydraChainContract
      inspector.address, // newHydraDelegation (using inspector for simplicity)
      owner.address, // newAPRCalculatorContract
      owner.address, // newHydraStakingRewardCalculatorContract
      owner.address, // newRewardWalletContract
      owner.address // newLiquidityToken
    );

    // Deploy Slashing contract
    const SlashingFactory = await ethers.getContractFactory("Slashing");
    slashing = await SlashingFactory.deploy();
    await slashing.deployed();

    // Initialize Slashing contract
    await slashing.connect(systemSigner).initialize(
      inspector.address,
      hydraStaking.address,
      governance.address,
      treasury.address
    );

    // Set slashing contract in HydraChain
    await inspector.connect(governance).setSlashingContract(slashing.address);

    // Set slashing contract in HydraStaking
    await hydraStaking.connect(governance).setSlashingContract(slashing.address);

    // Stake for all validators
    await hydraStaking.connect(validator1).stake({ value: ethers.utils.parseEther("1000") });
    await hydraStaking.connect(validator2).stake({ value: ethers.utils.parseEther("1000") });
    await hydraStaking.connect(validator3).stake({ value: ethers.utils.parseEther("1000") });
  });

  describe("Whistleblower Reward Distribution", function () {
    it("should correctly distribute 5% whistleblower reward to reporter", async function () {
      // Create double signing evidence
      const height = 100;
      const round = 0;
      const msgType = 1; // PREPARE

      const msg1Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "address"],
        [msgType, height, round, validator1.address]
      );
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "address", "bytes32"],
        [msgType, height, round, validator1.address, ethers.utils.keccak256("0x1234")]
      );

      const msg1Hash = ethers.utils.keccak256(msg1Data);
      const msg2Hash = ethers.utils.keccak256(msg2Data);

      const msg1Sig = await signRawHash(validator1Wallet, msg1Data);
      const msg2Sig = await signRawHash(validator1Wallet, msg2Data);

      // Get initial balances
      const reporterBalanceBefore = await ethers.provider.getBalance(reporter.address);
      const validator1StakeBefore = await hydraStaking.stakeOf(validator1.address);

      // Slash validator with reporter
      const tx = await slashing.connect(systemSigner).slashValidator(
        validator1.address,
        msg1Hash,
        msg1Sig,
        msg2Hash,
        msg2Sig,
        height,
        round,
        msgType,
        "double-signing",
        reporter.address
      );

      const receipt = await tx.wait();

      // Check WhistleblowerRewarded event
      const whistleblowerEvent = receipt.events?.find(
        (e: any) => e.event === "WhistleblowerRewarded"
      );
      expect(whistleblowerEvent).to.not.be.undefined;

      const rewardAmount = whistleblowerEvent!.args!.reward;
      const lockedFunds = await slashing.lockedFunds(validator1.address);

      // Verify 5% reward calculation
      const totalSlashed = validator1StakeBefore;
      const expectedReward = totalSlashed.mul(500).div(10000); // 5%
      const expectedLocked = totalSlashed.sub(expectedReward);

      expect(rewardAmount).to.equal(expectedReward);
      expect(lockedFunds.amount).to.equal(expectedLocked);

      // Verify reporter received the reward
      const reporterBalanceAfter = await ethers.provider.getBalance(reporter.address);
      expect(reporterBalanceAfter.sub(reporterBalanceBefore)).to.equal(expectedReward);

      // Verify validator stake is zero
      const validator1StakeAfter = await hydraStaking.stakeOf(validator1.address);
      expect(validator1StakeAfter).to.equal(0);
    });

    it("should not distribute reward if reporter is zero address", async function () {
      const height = 100;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64"],
        [msgType, height, round]
      );
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0x5678")]
      );

      const msg1Hash = ethers.utils.keccak256(msg1Data);
      const msg2Hash = ethers.utils.keccak256(msg2Data);

      const msg1Sig = await signRawHash(validator1Wallet, msg1Data);
      const msg2Sig = await signRawHash(validator1Wallet, msg2Data);

      // Slash without reporter (zero address)
      const tx = await slashing.connect(systemSigner).slashValidator(
        validator1.address,
        msg1Hash,
        msg1Sig,
        msg2Hash,
        msg2Sig,
        height,
        round,
        msgType,
        "double-signing",
        ethers.constants.AddressZero
      );

      const receipt = await tx.wait();

      // Check that no WhistleblowerRewarded event was emitted
      const whistleblowerEvent = receipt.events?.find(
        (e: any) => e.event === "WhistleblowerRewarded"
      );
      expect(whistleblowerEvent).to.be.undefined;

      // All funds should be locked (no reward distributed)
      const lockedFunds = await slashing.lockedFunds(validator1.address);
      const validator1StakeBefore = ethers.utils.parseEther("1000");
      expect(lockedFunds.amount).to.equal(validator1StakeBefore);
    });

    it("should handle configurable whistleblower percentage", async function () {
      // Change whistleblower reward percentage to 10%
      await slashing.connect(governance).setWhistleblowerRewardPercentage(1000); // 10% = 1000 basis points

      const height = 100;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64"],
        [msgType, height, round]
      );
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xabcd")]
      );

      const msg1Hash = ethers.utils.keccak256(msg1Data);
      const msg2Hash = ethers.utils.keccak256(msg2Data);

      const msg1Sig = await signRawHash(validator1Wallet, msg1Data);
      const msg2Sig = await signRawHash(validator1Wallet, msg2Data);

      const validator1StakeBefore = await hydraStaking.stakeOf(validator1.address);

      // Slash with reporter
      await slashing.connect(systemSigner).slashValidator(
        validator1.address,
        msg1Hash,
        msg1Sig,
        msg2Hash,
        msg2Sig,
        height,
        round,
        msgType,
        "double-signing",
        reporter.address
      );

      const lockedFunds = await slashing.lockedFunds(validator1.address);

      // Verify 10% reward calculation
      const expectedReward = validator1StakeBefore.mul(1000).div(10000); // 10%
      const expectedLocked = validator1StakeBefore.sub(expectedReward);

      expect(lockedFunds.amount).to.equal(expectedLocked);
    });
  });

  describe("Governance Fund Management", function () {
    beforeEach(async function () {
      // Slash validator1 first
      const height = 100;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64"],
        [msgType, height, round]
      );
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0x9999")]
      );

      const msg1Hash = ethers.utils.keccak256(msg1Data);
      const msg2Hash = ethers.utils.keccak256(msg2Data);

      const msg1Sig = await signRawHash(validator1Wallet, msg1Data);
      const msg2Sig = await signRawHash(validator1Wallet, msg2Data);

      await slashing.connect(systemSigner).slashValidator(
        validator1.address,
        msg1Hash,
        msg1Sig,
        msg2Hash,
        msg2Sig,
        height,
        round,
        msgType,
        "double-signing",
        reporter.address
      );
    });

    it("should not allow burning funds before lock period ends", async function () {
      await expect(
        slashing.connect(governance).burnLockedFunds(validator1.address)
      ).to.be.revertedWithCustomError(slashing, "FundsStillLocked");
    });

    it("should not allow sending to treasury before lock period ends", async function () {
      await expect(
        slashing.connect(governance).sendToTreasury(validator1.address)
      ).to.be.revertedWithCustomError(slashing, "FundsStillLocked");
    });

    it("should successfully burn locked funds after lock period", async function () {
      // Fast forward 30 days
      await time.increase(LOCK_PERIOD + 1);

      const lockedAmount = (await slashing.lockedFunds(validator1.address)).amount;
      const stakingBalanceBefore = await ethers.provider.getBalance(hydraStaking.address);

      // Burn locked funds
      const tx = await slashing.connect(governance).burnLockedFunds(validator1.address);
      const receipt = await tx.wait();

      // Check FundsBurned event
      const burnEvent = receipt.events?.find((e: any) => e.event === "FundsBurned");
      expect(burnEvent).to.not.be.undefined;
      expect(burnEvent!.args!.validator).to.equal(validator1.address);
      expect(burnEvent!.args!.amount).to.equal(lockedAmount);

      // Verify funds were burned (sent to zero address)
      const stakingBalanceAfter = await ethers.provider.getBalance(hydraStaking.address);
      expect(stakingBalanceBefore.sub(stakingBalanceAfter)).to.equal(lockedAmount);

      // Verify funds are marked as withdrawn
      const lockedFunds = await slashing.lockedFunds(validator1.address);
      expect(lockedFunds.withdrawn).to.be.true;
    });

    it("should successfully send locked funds to treasury after lock period", async function () {
      // Fast forward 30 days
      await time.increase(LOCK_PERIOD + 1);

      const lockedAmount = (await slashing.lockedFunds(validator1.address)).amount;
      const treasuryBalanceBefore = await ethers.provider.getBalance(treasury.address);

      // Send to treasury
      const tx = await slashing.connect(governance).sendToTreasury(validator1.address);
      const receipt = await tx.wait();

      // Check FundsSentToTreasury event
      const treasuryEvent = receipt.events?.find((e: any) => e.event === "FundsSentToTreasury");
      expect(treasuryEvent).to.not.be.undefined;
      expect(treasuryEvent!.args!.validator).to.equal(validator1.address);
      expect(treasuryEvent!.args!.amount).to.equal(lockedAmount);
      expect(treasuryEvent!.args!.treasury).to.equal(treasury.address);

      // Verify treasury received the funds
      const treasuryBalanceAfter = await ethers.provider.getBalance(treasury.address);
      expect(treasuryBalanceAfter.sub(treasuryBalanceBefore)).to.equal(lockedAmount);

      // Verify funds are marked as withdrawn
      const lockedFunds = await slashing.lockedFunds(validator1.address);
      expect(lockedFunds.withdrawn).to.be.true;
    });

    it("should not allow double withdrawal of funds", async function () {
      // Fast forward and burn once
      await time.increase(LOCK_PERIOD + 1);
      await slashing.connect(governance).burnLockedFunds(validator1.address);

      // Try to burn again
      await expect(
        slashing.connect(governance).burnLockedFunds(validator1.address)
      ).to.be.revertedWithCustomError(slashing, "FundsAlreadyWithdrawn");
    });

    it("should handle batch burn correctly", async function () {
      // Slash validator2 and validator3
      for (const [validator, wallet] of [
        [validator2, validator2Wallet],
        [validator3, validator3Wallet],
      ]) {
        const height = 200;
        const round = 0;
        const msgType = 1;

        const msg1Data = ethers.utils.defaultAbiCoder.encode(
          ["uint8", "uint64", "uint64"],
          [msgType, height, round]
        );
        const msg2Data = ethers.utils.defaultAbiCoder.encode(
          ["uint8", "uint64", "uint64", "bytes32"],
          [msgType, height, round, ethers.utils.keccak256(ethers.utils.randomBytes(32))]
        );

        const msg1Hash = ethers.utils.keccak256(msg1Data);
        const msg2Hash = ethers.utils.keccak256(msg2Data);

        const msg1Sig = await signRawHash(wallet, msg1Data);
        const msg2Sig = await signRawHash(wallet, msg2Data);

        await slashing.connect(systemSigner).slashValidator(
          (validator as any).address,
          msg1Hash,
          msg1Sig,
          msg2Hash,
          msg2Sig,
          height,
          round,
          msgType,
          "double-signing",
          reporter.address
        );
      }

      // Fast forward 30 days
      await time.increase(LOCK_PERIOD + 1);

      // Batch burn all three validators
      const tx = await slashing.connect(governance).batchBurnLockedFunds([
        validator1.address,
        validator2.address,
        validator3.address,
      ]);

      const receipt = await tx.wait();

      // Check that all three FundsBurned events were emitted
      const burnEvents = receipt.events?.filter((e: any) => e.event === "FundsBurned");
      expect(burnEvents).to.have.length(3);

      // Verify all marked as withdrawn
      for (const validator of [validator1, validator2, validator3]) {
        const lockedFunds = await slashing.lockedFunds(validator.address);
        expect(lockedFunds.withdrawn).to.be.true;
      }
    });

    it("should handle batch send to treasury correctly", async function () {
      // Slash validator2
      const height = 200;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64"],
        [msgType, height, round]
      );
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xeeee")]
      );

      const msg1Hash = ethers.utils.keccak256(msg1Data);
      const msg2Hash = ethers.utils.keccak256(msg2Data);

      const msg1Sig = await signRawHash(validator2Wallet, msg1Data);
      const msg2Sig = await signRawHash(validator2Wallet, msg2Data);

      await slashing.connect(systemSigner).slashValidator(
        validator2.address,
        msg1Hash,
        msg1Sig,
        msg2Hash,
        msg2Sig,
        height,
        round,
        msgType,
        "double-signing",
        reporter.address
      );

      // Fast forward 30 days
      await time.increase(LOCK_PERIOD + 1);

      const treasuryBalanceBefore = await ethers.provider.getBalance(treasury.address);

      // Batch send to treasury
      await slashing.connect(governance).batchSendToTreasury([
        validator1.address,
        validator2.address,
      ]);

      const treasuryBalanceAfter = await ethers.provider.getBalance(treasury.address);
      const totalSent = treasuryBalanceAfter.sub(treasuryBalanceBefore);

      // Verify treasury received funds from both validators
      expect(totalSent).to.be.gt(0);
    });

    it("should only allow governance to manage funds", async function () {
      await time.increase(LOCK_PERIOD + 1);

      await expect(
        slashing.connect(owner).burnLockedFunds(validator1.address)
      ).to.be.revertedWithCustomError(slashing, "OnlyGovernance");

      await expect(
        slashing.connect(owner).sendToTreasury(validator1.address)
      ).to.be.revertedWithCustomError(slashing, "OnlyGovernance");
    });
  });

  describe("Rate Limiting", function () {
    it("should enforce max slashings per block", async function () {
      // Set max slashings per block to 2
      await slashing.connect(governance).setMaxSlashingsPerBlock(2);

      // Create slashing evidence for 3 validators
      const slashingData = [];
      for (const [validator, wallet] of [
        [validator1, validator1Wallet],
        [validator2, validator2Wallet],
        [validator3, validator3Wallet],
      ]) {
        const height = 100;
        const round = 0;
        const msgType = 1;

        const msg1Data = ethers.utils.defaultAbiCoder.encode(
          ["uint8", "uint64", "uint64"],
          [msgType, height, round]
        );
        const msg2Data = ethers.utils.defaultAbiCoder.encode(
          ["uint8", "uint64", "uint64", "bytes32"],
          [msgType, height, round, ethers.utils.keccak256(ethers.utils.randomBytes(32))]
        );

        slashingData.push({
          validator: (validator as any).address,
          msg1Hash: ethers.utils.keccak256(msg1Data),
          msg2Hash: ethers.utils.keccak256(msg2Data),
          msg1Sig: await signRawHash(wallet, msg1Data),
          msg2Sig: await signRawHash(wallet, msg2Data),
        });
      }

      // Slash first two validators - should succeed
      await slashing.connect(systemSigner).slashValidator(
        slashingData[0].validator,
        slashingData[0].msg1Hash,
        slashingData[0].msg1Sig,
        slashingData[0].msg2Hash,
        slashingData[0].msg2Sig,
        100,
        0,
        1,
        "double-signing",
        reporter.address
      );

      await slashing.connect(systemSigner).slashValidator(
        slashingData[1].validator,
        slashingData[1].msg1Hash,
        slashingData[1].msg1Sig,
        slashingData[1].msg2Hash,
        slashingData[1].msg2Sig,
        100,
        0,
        1,
        "double-signing",
        reporter.address
      );

      // Third slashing in same block should fail
      await expect(
        slashing.connect(systemSigner).slashValidator(
          slashingData[2].validator,
          slashingData[2].msg1Hash,
          slashingData[2].msg1Sig,
          slashingData[2].msg2Hash,
          slashingData[2].msg2Sig,
          100,
          0,
          1,
          "double-signing",
          reporter.address
        )
      ).to.be.revertedWithCustomError(slashing, "MaxSlashingsExceeded");

      // Mine a new block
      await ethers.provider.send("evm_mine", []);

      // Now third slashing should succeed
      await expect(
        slashing.connect(systemSigner).slashValidator(
          slashingData[2].validator,
          slashingData[2].msg1Hash,
          slashingData[2].msg1Sig,
          slashingData[2].msg2Hash,
          slashingData[2].msg2Sig,
          100,
          0,
          1,
          "double-signing",
          reporter.address
        )
      ).to.not.be.reverted;
    });

    it("should reset counter for new blocks", async function () {
      await slashing.connect(governance).setMaxSlashingsPerBlock(1);

      // Slash validator1 in block N
      const height = 100;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64"],
        [msgType, height, round]
      );
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xaaaa")]
      );

      await slashing.connect(systemSigner).slashValidator(
        validator1.address,
        ethers.utils.keccak256(msg1Data),
        await signRawHash(validator1Wallet, msg1Data),
        ethers.utils.keccak256(msg2Data),
        await signRawHash(validator1Wallet, msg2Data),
        height,
        round,
        msgType,
        "double-signing",
        reporter.address
      );

      // Mine a new block
      await ethers.provider.send("evm_mine", []);

      // Slash validator2 in block N+1 - should succeed
      const msg1Data2 = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64"],
        [msgType, height, round]
      );
      const msg2Data2 = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xbbbb")]
      );

      await expect(
        slashing.connect(systemSigner).slashValidator(
          validator2.address,
          ethers.utils.keccak256(msg1Data2),
          await signRawHash(validator2Wallet, msg1Data2),
          ethers.utils.keccak256(msg2Data2),
          await signRawHash(validator2Wallet, msg2Data2),
          height,
          round,
          msgType,
          "double-signing",
          reporter.address
        )
      ).to.not.be.reverted;
    });
  });

  describe("Edge Cases and Security", function () {
    it("should handle zero stake validator gracefully", async function () {
      // Unstake all funds
      const stake = await hydraStaking.stakeOf(validator1.address);
      await hydraStaking.connect(validator1).unstake(stake);

      // Wait for unstaking period (if any)
      await time.increase(7 * 24 * 60 * 60); // 7 days

      // Try to slash validator with zero stake
      const height = 100;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64"],
        [msgType, height, round]
      );
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xcccc")]
      );

      const msg1Hash = ethers.utils.keccak256(msg1Data);
      const msg2Hash = ethers.utils.keccak256(msg2Data);

      const msg1Sig = await signRawHash(validator1Wallet, msg1Data);
      const msg2Sig = await signRawHash(validator1Wallet, msg2Data);

      // Slashing should still work (validator gets marked, but no funds to lock)
      await expect(
        slashing.connect(systemSigner).slashValidator(
          validator1.address,
          msg1Hash,
          msg1Sig,
          msg2Hash,
          msg2Sig,
          height,
          round,
          msgType,
          "double-signing",
          reporter.address
        )
      ).to.not.be.reverted;

      // Verify validator is marked as slashed
      expect(await slashing.hasBeenSlashed(validator1.address)).to.be.true;
    });

    it("should verify evidence hash is stored correctly", async function () {
      const height = 100;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64"],
        [msgType, height, round]
      );
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xdddd")]
      );

      const msg1Hash = ethers.utils.keccak256(msg1Data);
      const msg2Hash = ethers.utils.keccak256(msg2Data);

      const msg1Sig = await signRawHash(validator1Wallet, msg1Data);
      const msg2Sig = await signRawHash(validator1Wallet, msg2Data);

      await slashing.connect(systemSigner).slashValidator(
        validator1.address,
        msg1Hash,
        msg1Sig,
        msg2Hash,
        msg2Sig,
        height,
        round,
        msgType,
        "double-signing",
        reporter.address
      );

      // Verify evidence hash
      const storedHash = await slashing.getEvidenceHash(validator1.address);
      const expectedHash = ethers.utils.keccak256(
        ethers.utils.concat([msg1Hash, msg2Hash])
      );

      expect(storedHash).to.equal(expectedHash);
    });

    it("should handle governance address update", async function () {
      const newGovernance = validator3;

      // Update governance
      const tx = await slashing.connect(governance).setGovernance(newGovernance.address);
      const receipt = await tx.wait();

      // Check event
      const event = receipt.events?.find((e: any) => e.event === "GovernanceUpdated");
      expect(event).to.not.be.undefined;
      expect(event!.args!.newGovernance).to.equal(newGovernance.address);

      // Verify new governance works
      expect(await slashing.governance()).to.equal(newGovernance.address);

      // Old governance should no longer work
      await expect(
        slashing.connect(governance).setMaxSlashingsPerBlock(10)
      ).to.be.revertedWithCustomError(slashing, "OnlyGovernance");

      // New governance should work
      await expect(
        slashing.connect(newGovernance).setMaxSlashingsPerBlock(10)
      ).to.not.be.reverted;
    });

    it("should handle treasury address update", async function () {
      const newTreasury = validator3;

      // Update treasury
      await slashing.connect(governance).setDaoTreasury(newTreasury.address);

      expect(await slashing.daoTreasury()).to.equal(newTreasury.address);
    });

    it("should calculate remaining lock time correctly", async function () {
      // Slash validator1
      const height = 100;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64"],
        [msgType, height, round]
      );
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xffff")]
      );

      await slashing.connect(systemSigner).slashValidator(
        validator1.address,
        ethers.utils.keccak256(msg1Data),
        await signRawHash(validator1Wallet, msg1Data),
        ethers.utils.keccak256(msg2Data),
        await signRawHash(validator1Wallet, msg2Data),
        height,
        round,
        msgType,
        "double-signing",
        reporter.address
      );

      // Check initial remaining time
      let remainingTime = await slashing.getRemainingLockTime(validator1.address);
      expect(remainingTime).to.be.closeTo(LOCK_PERIOD, 5); // Within 5 seconds

      // Fast forward 15 days
      await time.increase(15 * 24 * 60 * 60);

      remainingTime = await slashing.getRemainingLockTime(validator1.address);
      expect(remainingTime).to.be.closeTo(15 * 24 * 60 * 60, 5); // ~15 days left

      // Fast forward past lock period
      await time.increase(16 * 24 * 60 * 60);

      remainingTime = await slashing.getRemainingLockTime(validator1.address);
      expect(remainingTime).to.equal(0); // Lock period ended
    });
  });

  describe("View Functions", function () {
    beforeEach(async function () {
      // Slash validator1
      const height = 100;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64"],
        [msgType, height, round]
      );
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0x1111")]
      );

      await slashing.connect(systemSigner).slashValidator(
        validator1.address,
        ethers.utils.keccak256(msg1Data),
        await signRawHash(validator1Wallet, msg1Data),
        ethers.utils.keccak256(msg2Data),
        await signRawHash(validator1Wallet, msg2Data),
        height,
        round,
        msgType,
        "double-signing",
        reporter.address
      );
    });

    it("should correctly return hasBeenSlashed", async function () {
      expect(await slashing.hasBeenSlashed(validator1.address)).to.be.true;
      expect(await slashing.hasBeenSlashed(validator2.address)).to.be.false;
    });

    it("should correctly return evidence hash", async function () {
      const evidenceHash = await slashing.getEvidenceHash(validator1.address);
      expect(evidenceHash).to.not.equal(ethers.constants.HashZero);
    });

    it("should correctly return locked funds info", async function () {
      const lockedFunds = await slashing.lockedFunds(validator1.address);
      expect(lockedFunds.amount).to.be.gt(0);
      expect(lockedFunds.withdrawn).to.be.false;
      expect(lockedFunds.lockTimestamp).to.be.gt(0);
    });

    it("should correctly return reporter address", async function () {
      const storedReporter = await slashing.slashingReporter(validator1.address);
      expect(storedReporter).to.equal(reporter.address);
    });

    it("should return configuration values", async function () {
      expect(await slashing.hydraChainContract()).to.equal(inspector.address);
      expect(await slashing.hydraStakingContract()).to.equal(hydraStaking.address);
      expect(await slashing.governance()).to.equal(governance.address);
      expect(await slashing.daoTreasury()).to.equal(treasury.address);
      expect(await slashing.LOCK_PERIOD()).to.equal(LOCK_PERIOD);
      expect(await slashing.whistleblowerRewardPercentage()).to.equal(500); // Default 5%
      expect(await slashing.maxSlashingsPerBlock()).to.equal(5); // Default
    });
  });
});
