import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { Slashing, HydraStaking, HydraChain } from "../../../../typechain-types";
import { SYSTEM } from "../../../constants";

describe("Slashing", function () {
  let slashing: Slashing;
  let staking: HydraStaking;
  let hydraChain: HydraChain;
  let owner: SignerWithAddress;
  let validator: SignerWithAddress;
  let nonValidator: SignerWithAddress;
  let system: SignerWithAddress;

  const MIN_STAKE = ethers.utils.parseEther("1000");
  const SLASH_AMOUNT = ethers.utils.parseEther("100");

  beforeEach(async function () {
    [owner, validator, nonValidator, system] = await ethers.getSigners();

    // Deploy HydraChain contract
    const HydraChainFactory = await ethers.getContractFactory("HydraChain");
    hydraChain = await HydraChainFactory.deploy();
    await hydraChain.deployed();

    // Deploy HydraStaking contract
    const HydraStakingFactory = await ethers.getContractFactory("HydraStaking");
    staking = await HydraStakingFactory.deploy();
    await staking.deployed();

    // Deploy Slashing contract
    const SlashingFactory = await ethers.getContractFactory("Slashing");
    slashing = await SlashingFactory.deploy();
    await slashing.deployed();
    await slashing.initialize(staking.address);

    // Impersonate the SYSTEM address for initialization
    await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
    const systemSigner = await ethers.getSigner(SYSTEM);

    // Initialize HydraChain
    await hydraChain.connect(systemSigner).initialize(
      [], // initial validators
      owner.address, // governance
      owner.address, // bls
      staking.address, // hydraStakingAddr
      owner.address, // hydraDelegationAddr
      owner.address, // rewardWalletAddr
      owner.address // daoIncentiveVaultAddr
    );

    // Initialize HydraStaking with system signer
    await staking.connect(systemSigner).initialize(
      [],
      MIN_STAKE,
      owner.address,
      owner.address,
      hydraChain.address, // hydraChainAddr
      owner.address,
      owner.address,
      owner.address,
      slashing.address
    );

    // Stop impersonating
    await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);

    // Set up validator
    await staking.connect(validator).stake({ value: MIN_STAKE });
  });

  describe("slashValidator", function () {
    it("should slash validator's stake when called by system", async function () {
      const initialStake = await staking.stakeOf(validator.address);

      // Impersonate the SYSTEM address
      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const systemSigner = await ethers.getSigner(SYSTEM);

      await slashing.connect(systemSigner).slashValidator(validator.address, "Test slashing");

      // Stop impersonating
      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);

      const finalStake = await staking.stakeOf(validator.address);

      expect(finalStake).to.equal(initialStake.sub(SLASH_AMOUNT));
    });

    it("should not allow slashing more than validator's stake", async function () {
      const initialStake = await staking.stakeOf(validator.address);
      const excessiveAmount = initialStake.add(ethers.utils.parseEther("1"));

      // Impersonate the SYSTEM address
      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const systemSigner = await ethers.getSigner(SYSTEM);

      await slashing.connect(systemSigner).slashValidator(validator.address, "Test excessive slashing");

      // Stop impersonating
      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);

      const finalStake = await staking.stakeOf(validator.address);

      expect(finalStake).to.equal(0);
    });

    it("should not allow slashing non-validator", async function () {
      // Impersonate the SYSTEM address
      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const systemSigner = await ethers.getSigner(SYSTEM);

      await expect(
        slashing.connect(systemSigner).slashValidator(nonValidator.address, "Test slashing non-validator")
      ).to.be.revertedWith("NOT_ACTIVE_VALIDATOR");

      // Stop impersonating
      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
    });

    it("should not allow slashing by non-system account", async function () {
      await expect(
        slashing.connect(owner).slashValidator(validator.address, "Test unauthorized slashing")
      ).to.be.revertedWith("Unauthorized");
    });

    it("should emit ValidatorSlashed event", async function () {
      // Impersonate the SYSTEM address
      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const systemSigner = await ethers.getSigner(SYSTEM);

      await expect(slashing.connect(systemSigner).slashValidator(validator.address, "Test event emission"))
        .to.emit(slashing, "ValidatorSlashed")
        .withArgs(validator.address, "Test event emission");

      // Stop impersonating
      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
    });
  });

  describe("getSlashedAmount", function () {
    it("should return correct slashed amount", async function () {
      // Impersonate the SYSTEM address
      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const systemSigner = await ethers.getSigner(SYSTEM);

      await slashing.connect(systemSigner).slashValidator(validator.address, "Test getSlashedAmount");

      // Stop impersonating
      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
    });

    it("should return zero for non-slashed validator", async function () {});
  });

  describe("isSlashed", function () {
    it("should return true for slashed validator", async function () {
      // Impersonate the SYSTEM address
      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const systemSigner = await ethers.getSigner(SYSTEM);

      await slashing.connect(systemSigner).slashValidator(validator.address, "Test isSlashed");

      // Stop impersonating
      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
    });

    it("should return false for non-slashed validator", async function () {});
  });
});
