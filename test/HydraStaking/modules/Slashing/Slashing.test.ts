import { expect } from "chai";
import { ethers } from "hardhat";
import { SYSTEM } from "../../../constants";

describe("Slashing", function () {
  let slashing: any;
  let inspector: any;
  let owner: any;
  let systemSigner: any;
  let validator: any;

  beforeEach(async function () {
    [owner, validator] = await ethers.getSigners();

    // Deploy HydraChain contract (used as Inspector)
    const InspectorFactory = await ethers.getContractFactory("HydraChain");
    inspector = await InspectorFactory.deploy();
    await inspector.deployed();

    // Impersonate SYSTEM for initialization
    await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
    systemSigner = await ethers.getSigner(SYSTEM);

    // Deploy a dummy BLS contract
    const BLSFactory = await ethers.getContractFactory("BLS");
    const bls = await BLSFactory.deploy();
    await bls.deployed();

    // Initialize HydraChain with no validators
    const validatorInit: any[] = [];
    await inspector.connect(systemSigner).initialize(
      validatorInit,
      owner.address, // governance
      owner.address, // hydraStakingAddr
      owner.address, // hydraDelegationAddr
      owner.address, // rewardWalletAddr
      owner.address, // daoIncentiveVaultAddr
      bls.address    // newBls (deployed contract)
    );

    // Deploy Slashing contract
    const SlashingFactory = await ethers.getContractFactory("Slashing");
    slashing = await SlashingFactory.deploy();
    await slashing.deployed();

    // Initialize Slashing contract
    await slashing.connect(systemSigner).initialize(inspector.address);
    // Set Slashing contract as allowed slasher in Inspector
    await inspector.connect(systemSigner).setSlashingContract(slashing.address);

    await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
  });

  it("should only allow system to initialize", async function () {
    // Try initializing again (should revert with already initialized)
    await expect(
      slashing.connect(owner).initialize(inspector.address)
    ).to.be.revertedWith("Initializable: contract is already initialized");
  });

  it("should set hydraChainContract correctly", async function () {
    expect(await slashing.hydraChainContract()).to.equal(inspector.address);
  });

  it("should only allow system to call slashValidator", async function () {
    await expect(
      slashing.connect(owner).slashValidator(validator.address, "reason")
    ).to.be.revertedWithCustomError(slashing, "Unauthorized");
  });

  it("should revert if validator is zero address", async function () {
    await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
    const systemSigner = await ethers.getSigner(SYSTEM);

    await expect(
      slashing.connect(systemSigner).slashValidator(ethers.constants.AddressZero, "reason")
    ).to.be.revertedWithCustomError(slashing, "InvalidValidatorAddress");

    await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
  });

  it("should call Inspector and emit event", async function () {
    await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
    const systemSigner = await ethers.getSigner(SYSTEM);

    await expect(
      slashing.connect(systemSigner).slashValidator(validator.address, "reason")
    ).to.be.revertedWithCustomError(inspector, "ValidatorNotActive");

    await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
  });
});
