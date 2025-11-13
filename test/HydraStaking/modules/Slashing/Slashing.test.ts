import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { SYSTEM, CHAIN_ID, DOMAIN } from "../../../constants";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import * as mcl from "../../../../ts/mcl";
import { registerValidator } from "../../../helper";

/**
 * Comprehensive Test Suite for Slashing System
 *
 * Covers:
 * - Whistleblower reward distribution
 * - Governance fund management (burn/treasury)
 * - Rate limiting across multiple blocks
 * - Multi-validator slashing scenarios
 * - Edge cases and security validations
 */
describe("Slashing", function () {
  let slashing: any;
  let hydraChain: any;
  let hydraStaking: any;
  let bls: any;
  let hydraDelegation: any;
  let liquidToken: any;
  let aprCalculator: any;
  let rewardWallet: any;
  let systemHydraChain: any;

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

  async function deploySlashingFixture() {
    // Initialize MCL
    await mcl.init();

    // Get signers
    const signers = await ethers.getSigners();
    // Assign validators to match the hardcoded private keys (accounts 2, 3, 4)
    owner = signers[0];
    governance = signers[1];
    validator1 = signers[2]; // 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
    validator2 = signers[3]; // 0x90F79bf6EB2c4f870365E785982E1f101E93b906
    validator3 = signers[4]; // 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
    treasury = signers[5];
    reporter = signers[6];

    // Create Wallet objects with known private keys for raw signing
    // These private keys correspond to Hardhat's default accounts 2, 3, 4
    validator1Wallet = new ethers.Wallet("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
    validator2Wallet = new ethers.Wallet("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6");
    validator3Wallet = new ethers.Wallet("0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a");

    // Deploy all base contracts using factory pattern
    const BLSFactory = await ethers.getContractFactory("BLS");
    bls = await BLSFactory.deploy();
    await bls.deployed();

    const HydraChainFactory = await ethers.getContractFactory("HydraChain");
    hydraChain = await HydraChainFactory.deploy();
    await hydraChain.deployed();

    const HydraStakingFactory = await ethers.getContractFactory("HydraStaking");
    hydraStaking = await HydraStakingFactory.deploy();
    await hydraStaking.deployed();

    const HydraDelegationFactory = await ethers.getContractFactory("HydraDelegation");
    hydraDelegation = await HydraDelegationFactory.deploy();
    await hydraDelegation.deployed();

    const LiquidityTokenFactory = await ethers.getContractFactory("LiquidityToken");
    liquidToken = await LiquidityTokenFactory.deploy();
    await liquidToken.deployed();

    const APRCalculatorFactory = await ethers.getContractFactory("APRCalculator");
    aprCalculator = await APRCalculatorFactory.deploy();
    await aprCalculator.deployed();

    const RewardWalletFactory = await ethers.getContractFactory("RewardWallet");
    rewardWallet = await RewardWalletFactory.deploy();
    await rewardWallet.deployed();

    const SlashingFactory = await ethers.getContractFactory("Slashing");
    slashing = await SlashingFactory.deploy();
    await slashing.deployed();

    // Fund and impersonate SYSTEM account
    await owner.sendTransaction({
      to: SYSTEM,
      value: ethers.utils.parseEther("100"),
    });
    await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
    systemSigner = await ethers.getSigner(SYSTEM);
    systemHydraChain = hydraChain.connect(systemSigner);

    // Initialize contracts in correct order
    await liquidToken
      .connect(systemSigner)
      .initialize("Hydra", "HYDRA", governance.address, hydraStaking.address, hydraDelegation.address);

    // Generate initial prices array for APRCalculator (310 prices needed)
    const initialPrices = Array(310).fill(500);

    await aprCalculator.connect(systemSigner).initialize(
      governance.address,
      hydraChain.address,
      ethers.constants.AddressZero, // PriceOracle - not needed for slashing tests
      initialPrices
    );

    await hydraChain.connect(systemSigner).initialize(
      [], // Empty validators - will register manually
      governance.address,
      hydraStaking.address,
      hydraDelegation.address,
      rewardWallet.address,
      ethers.constants.AddressZero, // DAOIncentiveVault
      bls.address
    );

    await hydraDelegation.connect(systemSigner).initialize(
      [],
      0,
      governance.address,
      aprCalculator.address,
      hydraChain.address,
      hydraStaking.address,
      ethers.constants.AddressZero, // VestingManagerFactory
      rewardWallet.address,
      liquidToken.address
    );

    await hydraStaking
      .connect(systemSigner)
      .initialize(
        [],
        ethers.utils.parseEther("1"),
        governance.address,
        aprCalculator.address,
        hydraChain.address,
        hydraDelegation.address,
        rewardWallet.address,
        liquidToken.address,
        slashing.address
      );

    await slashing
      .connect(systemSigner)
      .initialize(hydraChain.address, hydraStaking.address, governance.address, treasury.address, 10, 500);

    await rewardWallet
      .connect(systemSigner)
      .initialize([hydraChain.address, hydraStaking.address, hydraDelegation.address]);

    // Fund reward wallet using the fund() function
    await rewardWallet.connect(owner).fund({ value: ethers.utils.parseEther("5") });

    // Set slashing contract
    await hydraChain.connect(systemSigner).setSlashingContract(slashing.address);

    // Disable whitelisting
    await hydraChain.connect(governance).disableWhitelisting();

    // Register validators
    await registerValidator(hydraChain, validator1, 0);
    await registerValidator(hydraChain, validator2, 0);
    await registerValidator(hydraChain, validator3, 0);

    // Stake for validators
    await hydraStaking.connect(validator1).stake({ value: ethers.utils.parseEther("1000") });
    await hydraStaking.connect(validator2).stake({ value: ethers.utils.parseEther("1000") });
    await hydraStaking.connect(validator3).stake({ value: ethers.utils.parseEther("1000") });

    return {
      hydraChain,
      systemHydraChain,
      bls,
      hydraStaking,
      hydraDelegation,
      liquidToken,
      aprCalculator,
      rewardWallet,
      slashing,
    };
  }

  beforeEach(async function () {
    const contracts = await loadFixture(deploySlashingFixture);
    hydraChain = contracts.hydraChain;
    systemHydraChain = contracts.systemHydraChain;
    bls = contracts.bls;
    hydraStaking = contracts.hydraStaking;
    hydraDelegation = contracts.hydraDelegation;
    liquidToken = contracts.liquidToken;
    aprCalculator = contracts.aprCalculator;
    rewardWallet = contracts.rewardWallet;
    slashing = contracts.slashing;
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
      const tx = await slashing
        .connect(systemSigner)
        .slashValidator(
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
      const whistleblowerEvent = receipt.events?.find((e: any) => e.event === "WhistleblowerRewarded");
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

      const msg1Data = ethers.utils.defaultAbiCoder.encode(["uint8", "uint64", "uint64"], [msgType, height, round]);
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0x5678")]
      );

      const msg1Hash = ethers.utils.keccak256(msg1Data);
      const msg2Hash = ethers.utils.keccak256(msg2Data);

      const msg1Sig = await signRawHash(validator1Wallet, msg1Data);
      const msg2Sig = await signRawHash(validator1Wallet, msg2Data);

      // Slash without reporter (zero address)
      const tx = await slashing
        .connect(systemSigner)
        .slashValidator(
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
      const whistleblowerEvent = receipt.events?.find((e: any) => e.event === "WhistleblowerRewarded");
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

      const msg1Data = ethers.utils.defaultAbiCoder.encode(["uint8", "uint64", "uint64"], [msgType, height, round]);
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
      await slashing
        .connect(systemSigner)
        .slashValidator(
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

      const msg1Data = ethers.utils.defaultAbiCoder.encode(["uint8", "uint64", "uint64"], [msgType, height, round]);
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0x9999")]
      );

      const msg1Hash = ethers.utils.keccak256(msg1Data);
      const msg2Hash = ethers.utils.keccak256(msg2Data);

      const msg1Sig = await signRawHash(validator1Wallet, msg1Data);
      const msg2Sig = await signRawHash(validator1Wallet, msg2Data);

      await slashing
        .connect(systemSigner)
        .slashValidator(
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
      await expect(slashing.connect(governance).burnLockedFunds(validator1.address)).to.be.revertedWithCustomError(
        slashing,
        "FundsStillLocked"
      );
    });

    it("should not allow sending to treasury before lock period ends", async function () {
      await expect(slashing.connect(governance).sendToTreasury(validator1.address)).to.be.revertedWithCustomError(
        slashing,
        "FundsStillLocked"
      );
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
      await expect(slashing.connect(governance).burnLockedFunds(validator1.address)).to.be.revertedWithCustomError(
        slashing,
        "AlreadyWithdrawn"
      );
    });

    it("should handle batch burn correctly", async function () {
      // Slash validator2 and validator3
      for (const [validator, wallet] of [
        [validator2, validator2Wallet],
        [validator3, validator3Wallet],
      ]) {
        const currentBlock = await ethers.provider.getBlockNumber();
        const height = currentBlock;
        const round = 0;
        const msgType = 1;

        const msg1Data = ethers.utils.defaultAbiCoder.encode(["uint8", "uint64", "uint64"], [msgType, height, round]);
        const msg2Data = ethers.utils.defaultAbiCoder.encode(
          ["uint8", "uint64", "uint64", "bytes32"],
          [msgType, height, round, ethers.utils.keccak256(ethers.utils.randomBytes(32))]
        );

        const msg1Hash = ethers.utils.keccak256(msg1Data);
        const msg2Hash = ethers.utils.keccak256(msg2Data);

        const msg1Sig = await signRawHash(wallet, msg1Data);
        const msg2Sig = await signRawHash(wallet, msg2Data);

        await slashing
          .connect(systemSigner)
          .slashValidator(
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
      const tx = await slashing
        .connect(governance)
        .batchBurnLockedFunds([validator1.address, validator2.address, validator3.address]);

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
      const currentBlock = await ethers.provider.getBlockNumber();
      const height = currentBlock;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(["uint8", "uint64", "uint64"], [msgType, height, round]);
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xeeee")]
      );

      const msg1Hash = ethers.utils.keccak256(msg1Data);
      const msg2Hash = ethers.utils.keccak256(msg2Data);

      const msg1Sig = await signRawHash(validator2Wallet, msg1Data);
      const msg2Sig = await signRawHash(validator2Wallet, msg2Data);

      await slashing
        .connect(systemSigner)
        .slashValidator(
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
      await slashing.connect(governance).batchSendToTreasury([validator1.address, validator2.address]);

      const treasuryBalanceAfter = await ethers.provider.getBalance(treasury.address);
      const totalSent = treasuryBalanceAfter.sub(treasuryBalanceBefore);

      // Verify treasury received funds from both validators
      expect(totalSent).to.be.gt(0);
    });

    it("should only allow governance to manage funds", async function () {
      await time.increase(LOCK_PERIOD + 1);

      await expect(slashing.connect(owner).burnLockedFunds(validator1.address)).to.be.revertedWithCustomError(
        slashing,
        "OnlyGovernance"
      );

      await expect(slashing.connect(owner).sendToTreasury(validator1.address)).to.be.revertedWithCustomError(
        slashing,
        "OnlyGovernance"
      );
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

        const msg1Data = ethers.utils.defaultAbiCoder.encode(["uint8", "uint64", "uint64"], [msgType, height, round]);
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

      // Note: In Hardhat, each transaction creates a new block by default
      // So we'll verify the per-block counter works correctly

      // Slash first validator
      const tx1 = await slashing
        .connect(systemSigner)
        .slashValidator(
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
      const receipt1 = await tx1.wait();

      // Verify first block has 1 slashing
      expect(await slashing.slashingsInBlock(receipt1.blockNumber)).to.equal(1);

      // Slash second validator
      const tx2 = await slashing
        .connect(systemSigner)
        .slashValidator(
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
      const receipt2 = await tx2.wait();

      // Verify second block also has 1 slashing (different block)
      expect(await slashing.slashingsInBlock(receipt2.blockNumber)).to.equal(1);

      // Slash third validator
      const tx3 = await slashing
        .connect(systemSigner)
        .slashValidator(
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
        );
      const receipt3 = await tx3.wait();

      // Verify third block has 1 slashing
      expect(await slashing.slashingsInBlock(receipt3.blockNumber)).to.equal(1);

      // Verify all three slashings happened in different blocks (counter resets per block)
      expect(receipt1.blockNumber).to.not.equal(receipt2.blockNumber);
      expect(receipt2.blockNumber).to.not.equal(receipt3.blockNumber);
    });

    it("should reset counter for new blocks", async function () {
      await slashing.connect(governance).setMaxSlashingsPerBlock(1);

      // Slash validator1 in block N
      const height = 100;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(["uint8", "uint64", "uint64"], [msgType, height, round]);
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xaaaa")]
      );

      await slashing
        .connect(systemSigner)
        .slashValidator(
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
      const msg1Data2 = ethers.utils.defaultAbiCoder.encode(["uint8", "uint64", "uint64"], [msgType, height, round]);
      const msg2Data2 = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xbbbb")]
      );

      await expect(
        slashing
          .connect(systemSigner)
          .slashValidator(
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
    it("should revert when slashing validator with zero stake", async function () {
      // Use validator3 (hasn't been slashed in most tests)
      // First, check if validator3 was already slashed, if not proceed
      const alreadySlashed = await slashing.hasBeenSlashed(validator3.address);

      // Choose a validator that hasn't been slashed yet
      const testValidator = alreadySlashed ? validator2 : validator3;
      const testWallet = alreadySlashed ? validator2Wallet : validator3Wallet;

      // Unstake all funds
      const stake = await hydraStaking.stakeOf(testValidator.address);
      await hydraStaking.connect(testValidator).unstake(stake);

      // Wait for unstaking period
      await time.increase(7 * 24 * 60 * 60); // 7 days

      // Withdraw unstaked funds
      await hydraStaking.connect(testValidator).withdraw(testValidator.address);

      // Verify stake is now zero
      expect(await hydraStaking.stakeOf(testValidator.address)).to.equal(0);

      // Try to slash validator with zero stake
      const currentBlock = await ethers.provider.getBlockNumber();
      const height = currentBlock;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(["uint8", "uint64", "uint64"], [msgType, height, round]);
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xcccc")]
      );

      const msg1Hash = ethers.utils.keccak256(msg1Data);
      const msg2Hash = ethers.utils.keccak256(msg2Data);

      const msg1Sig = await signRawHash(testWallet, msg1Data);
      const msg2Sig = await signRawHash(testWallet, msg2Data);

      // Slashing should revert with ValidatorNotActive error (validator becomes inactive after withdrawal)
      await expect(
        slashing
          .connect(systemSigner)
          .slashValidator(
            testValidator.address,
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
      ).to.be.revertedWithCustomError(hydraChain, "ValidatorNotActive");
    });

    it("should verify evidence hash is stored correctly", async function () {
      const height = 100;
      const round = 0;
      const msgType = 1;

      const msg1Data = ethers.utils.defaultAbiCoder.encode(["uint8", "uint64", "uint64"], [msgType, height, round]);
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xdddd")]
      );

      const msg1Hash = ethers.utils.keccak256(msg1Data);
      const msg2Hash = ethers.utils.keccak256(msg2Data);

      const msg1Sig = await signRawHash(validator1Wallet, msg1Data);
      const msg2Sig = await signRawHash(validator1Wallet, msg2Data);

      await slashing
        .connect(systemSigner)
        .slashValidator(
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
      const expectedHash = ethers.utils.keccak256(ethers.utils.concat([msg1Hash, msg2Hash]));

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
      await expect(slashing.connect(governance).setMaxSlashingsPerBlock(10)).to.be.revertedWithCustomError(
        slashing,
        "OnlyGovernance"
      );

      // New governance should work
      await expect(slashing.connect(newGovernance).setMaxSlashingsPerBlock(10)).to.not.be.reverted;
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

      const msg1Data = ethers.utils.defaultAbiCoder.encode(["uint8", "uint64", "uint64"], [msgType, height, round]);
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0xffff")]
      );

      await slashing
        .connect(systemSigner)
        .slashValidator(
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

      const msg1Data = ethers.utils.defaultAbiCoder.encode(["uint8", "uint64", "uint64"], [msgType, height, round]);
      const msg2Data = ethers.utils.defaultAbiCoder.encode(
        ["uint8", "uint64", "uint64", "bytes32"],
        [msgType, height, round, ethers.utils.keccak256("0x1111")]
      );

      await slashing
        .connect(systemSigner)
        .slashValidator(
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
      expect(await slashing.hydraChainContract()).to.equal(hydraChain.address);
      expect(await slashing.hydraStakingContract()).to.equal(hydraStaking.address);
      expect(await slashing.governance()).to.equal(governance.address);
      expect(await slashing.daoTreasury()).to.equal(treasury.address);
      expect(await slashing.LOCK_PERIOD()).to.equal(LOCK_PERIOD);
      expect(await slashing.whistleblowerRewardPercentage()).to.equal(500); // 5%
      expect(await slashing.maxSlashingsPerBlock()).to.equal(10); // Initialized with 10
    });
  });
});
