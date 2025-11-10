import { expect } from "chai";
import { ethers } from "hardhat";
import { SYSTEM } from "../../../constants";

/**
 * Comprehensive E2E test for ECDSA-based slashing functionality
 * This test replicates the exact flow that happens in the Go node
 */
describe("Slashing ECDSA E2E Tests", function () {
  let slashing: any;
  let inspector: any;
  let owner: any;
  let governance: any;
  let systemSigner: any;
  let validator: any;
  let validator2: any;

  // Wallets with known private keys for raw signing
  let validatorWallet: any;
  let validator2Wallet: any;

  // Helper function to create IBFT message structure matching Go code
  function createIBFTMessage(
    msgType: number,
    height: number,
    round: number,
    from: string,
    data: string,
    signature: string
  ) {
    return {
      msgType,
      height,
      round,
      from,
      signature: ethers.utils.arrayify(signature),
      data: ethers.utils.arrayify(data),
    };
  }

  // Helper to sign a message with a wallet (replicating Go's SignIBFTMessage)
  // IMPORTANT: Go code signs the RAW hash without Ethereum prefix
  // This matches crypto.Ecdsa.Sign(keccak256(data)) in Go
  async function signIBFTMessage(wallet: any, data: string): Promise<string> {
    const dataBytes = ethers.utils.arrayify(data);
    const hash = ethers.utils.keccak256(dataBytes);

    // Sign the raw hash WITHOUT Ethereum signed message prefix
    // This is critical - Go's ECDSA signing doesn't add any prefix
    const signature = wallet._signingKey().signDigest(hash);

    // Combine r, s, v into a single signature bytes
    const sig = ethers.utils.joinSignature(signature);
    return sig;
  }

  beforeEach(async function () {
    [owner, governance, validator, validator2] = await ethers.getSigners();

    // Create Wallet objects from Hardhat's default private keys
    // These private keys correspond to the addresses from ethers.getSigners()
    const validatorPrivateKey = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"; // Account #2
    const validator2PrivateKey = "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"; // Account #3

    validatorWallet = new ethers.Wallet(validatorPrivateKey);
    validator2Wallet = new ethers.Wallet(validator2PrivateKey);

    console.log("\n=== Test Setup ===");
    console.log("Owner:", owner.address);
    console.log("Governance:", governance.address);
    console.log("Validator:", validator.address);
    console.log("Validator (wallet):", validatorWallet.address);
    console.log("Validator2:", validator2.address);
    console.log("Validator2 (wallet):", validator2Wallet.address);

    // Deploy HydraChain contract (Inspector)
    const InspectorFactory = await ethers.getContractFactory("HydraChain");
    inspector = await InspectorFactory.deploy();
    await inspector.deployed();
    console.log("HydraChain (Inspector) deployed:", inspector.address);

    // Fund SYSTEM account
    await owner.sendTransaction({
      to: SYSTEM,
      value: ethers.utils.parseEther("100"),
    });

    // Impersonate SYSTEM
    await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
    systemSigner = await ethers.getSigner(SYSTEM);

    // Deploy BLS contract
    const BLSFactory = await ethers.getContractFactory("BLS");
    const bls = await BLSFactory.deploy();
    await bls.deployed();

    // Initialize HydraChain with validators
    const validatorInit = [
      {
        addr: validator.address,
        pubkey: [ethers.constants.HashZero, ethers.constants.HashZero, ethers.constants.HashZero, ethers.constants.HashZero],
        signature: [ethers.constants.HashZero, ethers.constants.HashZero],
        stake: ethers.utils.parseEther("100"),
      },
      {
        addr: validator2.address,
        pubkey: [ethers.constants.HashZero, ethers.constants.HashZero, ethers.constants.HashZero, ethers.constants.HashZero],
        signature: [ethers.constants.HashZero, ethers.constants.HashZero],
        stake: ethers.utils.parseEther("100"),
      },
    ];

    await inspector.connect(systemSigner).initialize(
      validatorInit,
      governance.address,
      owner.address, // hydraStakingAddr
      owner.address, // hydraDelegationAddr
      owner.address, // rewardWalletAddr
      owner.address, // daoIncentiveVaultAddr
      bls.address
    );
    console.log("HydraChain initialized with 2 validators");

    // Deploy Slashing contract
    const SlashingFactory = await ethers.getContractFactory("Slashing");
    slashing = await SlashingFactory.deploy();
    await slashing.deployed();
    console.log("Slashing contract deployed:", slashing.address);

    // Initialize Slashing contract
    await slashing.connect(systemSigner).initialize(
      inspector.address,
      governance.address,
      ethers.constants.AddressZero, // daoTreasury (optional)
      100 // maxSlashingsPerBlock
    );
    console.log("Slashing contract initialized");

    // Set Slashing contract in Inspector
    await inspector.connect(systemSigner).setSlashingContract(slashing.address);
    console.log("Slashing contract set in Inspector");

    await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
  });

  describe("Contract Initialization", function () {
    it("should be properly initialized", async function () {
      console.log("\n=== Testing Initialization ===");

      const hydraChain = await slashing.hydraChainContract();
      console.log("hydraChainContract:", hydraChain);
      expect(hydraChain).to.equal(inspector.address);

      const gov = await slashing.governance();
      console.log("governance:", gov);
      expect(gov).to.equal(governance.address);

      const maxSlashings = await slashing.maxSlashingsPerBlock();
      console.log("maxSlashingsPerBlock:", maxSlashings.toString());
      expect(maxSlashings).to.equal(100);

      // Test ping function
      const pingResult = await slashing.ping();
      console.log("ping():", pingResult);
      expect(pingResult).to.be.true;
    });

    it("should not allow double initialization", async function () {
      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const sys = await ethers.getSigner(SYSTEM);

      await expect(
        slashing.connect(sys).initialize(
          inspector.address,
          governance.address,
          ethers.constants.AddressZero,
          100
        )
      ).to.be.revertedWith("Already initialized");

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
    });
  });

  describe("ECDSA Signature Verification", function () {
    it("should verify ECDSA signatures correctly", async function () {
      console.log("\n=== Testing ECDSA Signature Verification ===");

      // Create message data (simulating IBFT PREPREPARE message)
      const msgData1 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [92, 0, ethers.utils.randomBytes(32)]
      );
      const msgData2 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [92, 0, ethers.utils.randomBytes(32)]
      );

      console.log("Creating conflicting PREPREPARE messages at height 92, round 0");
      console.log("msg1Data hash:", ethers.utils.keccak256(msgData1));
      console.log("msg2Data hash:", ethers.utils.keccak256(msgData2));

      // Sign both messages with validator's key
      const sig1 = await signIBFTMessage(validatorWallet, msgData1);
      const sig2 = await signIBFTMessage(validatorWallet, msgData2);

      console.log("msg1 signature length:", ethers.utils.arrayify(sig1).length);
      console.log("msg2 signature length:", ethers.utils.arrayify(sig2).length);

      // Verify signatures are different
      expect(sig1).to.not.equal(sig2);

      // Create IBFT message structures
      const msg1 = createIBFTMessage(
        0, // PREPREPARE
        92,
        0,
        validator.address,
        msgData1,
        sig1
      );

      const msg2 = createIBFTMessage(
        0, // PREPREPARE
        92,
        0,
        validator.address,
        msgData2,
        sig2
      );

      console.log("\n=== Calling slashValidator ===");
      console.log("Validator to slash:", validator.address);
      console.log("msg1.msgType:", msg1.msgType);
      console.log("msg1.height:", msg1.height);
      console.log("msg1.round:", msg1.round);
      console.log("msg1.from:", msg1.from);
      console.log("msg1.signature length:", msg1.signature.length);
      console.log("msg1.data length:", msg1.data.length);

      // Impersonate SYSTEM to call slashValidator
      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const sys = await ethers.getSigner(SYSTEM);

      // Call slashValidator - this should succeed if ECDSA verification works
      const tx = await slashing
        .connect(sys)
        .slashValidator(validator.address, msg1, msg2, "Double signing PREPREPARE at height 92");

      const receipt = await tx.wait();
      console.log("\n=== Transaction Success ===");
      console.log("Gas used:", receipt.gasUsed.toString());
      console.log("Status:", receipt.status);

      // Check for events
      const doubleSignEvent = receipt.events?.find((e: any) => e.event === "DoubleSignEvidence");
      expect(doubleSignEvent).to.not.be.undefined;
      console.log("DoubleSignEvidence event emitted");

      const slashedEvent = receipt.events?.find((e: any) => e.event === "ValidatorSlashed");
      expect(slashedEvent).to.not.be.undefined;
      console.log("ValidatorSlashed event emitted");

      // Check SlashingStepCompleted events
      const stepEvents = receipt.events?.filter((e: any) => e.event === "SlashingStepCompleted");
      console.log(`\nSlashingStepCompleted events (${stepEvents?.length || 0}):`);
      stepEvents?.forEach((e: any) => {
        console.log(`  - ${e.args?.step}`);
      });

      // Verify validator was marked as slashed
      const hasBeenSlashed = await slashing.hasBeenSlashed(validator.address);
      expect(hasBeenSlashed).to.be.true;
      console.log("\nValidator marked as slashed:", hasBeenSlashed);

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
    });

    it("should reject if signatures don't match validator", async function () {
      console.log("\n=== Testing Invalid Signature Rejection ===");

      const msgData1 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [100, 0, ethers.utils.randomBytes(32)]
      );
      const msgData2 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [100, 0, ethers.utils.randomBytes(32)]
      );

      // Sign with validator2's key but claim it's from validator
      const sig1 = await signIBFTMessage(validator2Wallet, msgData1);
      const sig2 = await signIBFTMessage(validator2Wallet, msgData2);

      const msg1 = createIBFTMessage(0, 100, 0, validator.address, msgData1, sig1);
      const msg2 = createIBFTMessage(0, 100, 0, validator.address, msgData2, sig2);

      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const sys = await ethers.getSigner(SYSTEM);

      await expect(
        slashing.connect(sys).slashValidator(validator.address, msg1, msg2, "Invalid signature test")
      ).to.be.revertedWithCustomError(slashing, "InvalidSignature");

      console.log("Correctly rejected invalid signature");

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
    });

    it("should reject if messages have same data", async function () {
      console.log("\n=== Testing Same Data Rejection ===");

      const msgData = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [110, 0, ethers.utils.randomBytes(32)]
      );

      const sig1 = await signIBFTMessage(validatorWallet, msgData);
      const sig2 = await signIBFTMessage(validatorWallet, msgData); // Same data!

      const msg1 = createIBFTMessage(0, 110, 0, validator.address, msgData, sig1);
      const msg2 = createIBFTMessage(0, 110, 0, validator.address, msgData, sig2);

      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const sys = await ethers.getSigner(SYSTEM);

      await expect(
        slashing.connect(sys).slashValidator(validator.address, msg1, msg2, "Same data test")
      ).to.be.revertedWithCustomError(slashing, "EvidenceMismatch");

      console.log("Correctly rejected identical data");

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
    });

    it("should reject if messages have different heights", async function () {
      console.log("\n=== Testing Height Mismatch Rejection ===");

      const msgData1 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [120, 0, ethers.utils.randomBytes(32)]
      );
      const msgData2 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [121, 0, ethers.utils.randomBytes(32)] // Different height!
      );

      const sig1 = await signIBFTMessage(validatorWallet, msgData1);
      const sig2 = await signIBFTMessage(validatorWallet, msgData2);

      const msg1 = createIBFTMessage(0, 120, 0, validator.address, msgData1, sig1);
      const msg2 = createIBFTMessage(0, 121, 0, validator.address, msgData2, sig2); // Different height

      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const sys = await ethers.getSigner(SYSTEM);

      await expect(
        slashing.connect(sys).slashValidator(validator.address, msg1, msg2, "Height mismatch test")
      ).to.be.revertedWithCustomError(slashing, "EvidenceMismatch");

      console.log("Correctly rejected height mismatch");

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
    });

    it("should prevent double slashing same validator", async function () {
      console.log("\n=== Testing Double Slashing Prevention ===");

      // First slashing
      const msgData1 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [130, 0, ethers.utils.randomBytes(32)]
      );
      const msgData2 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [130, 0, ethers.utils.randomBytes(32)]
      );

      const sig1 = await signIBFTMessage(validator2Wallet, msgData1);
      const sig2 = await signIBFTMessage(validator2Wallet, msgData2);

      const msg1 = createIBFTMessage(0, 130, 0, validator2.address, msgData1, sig1);
      const msg2 = createIBFTMessage(0, 130, 0, validator2.address, msgData2, sig2);

      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const sys = await ethers.getSigner(SYSTEM);

      // First slash should succeed
      await slashing.connect(sys).slashValidator(validator2.address, msg1, msg2, "First slash");
      console.log("First slashing succeeded");

      // Second slash should fail
      const msgData3 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [140, 0, ethers.utils.randomBytes(32)]
      );
      const msgData4 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [140, 0, ethers.utils.randomBytes(32)]
      );

      const sig3 = await signIBFTMessage(validator2Wallet, msgData3);
      const sig4 = await signIBFTMessage(validator2Wallet, msgData4);

      const msg3 = createIBFTMessage(0, 140, 0, validator2.address, msgData3, sig3);
      const msg4 = createIBFTMessage(0, 140, 0, validator2.address, msgData4, sig4);

      await expect(
        slashing.connect(sys).slashValidator(validator2.address, msg3, msg4, "Second slash")
      ).to.be.revertedWithCustomError(slashing, "ValidatorAlreadySlashed");

      console.log("Correctly prevented double slashing");

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
    });
  });

  describe("Different Message Types", function () {
    it("should handle COMMIT messages", async function () {
      console.log("\n=== Testing COMMIT Message Type ===");

      const msgData1 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [150, 0, ethers.utils.randomBytes(32)]
      );
      const msgData2 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [150, 0, ethers.utils.randomBytes(32)]
      );

      const sig1 = await signIBFTMessage(validatorWallet, msgData1);
      const sig2 = await signIBFTMessage(validatorWallet, msgData2);

      // Use msgType 2 for COMMIT
      const msg1 = createIBFTMessage(2, 150, 0, validator.address, msgData1, sig1);
      const msg2 = createIBFTMessage(2, 150, 0, validator.address, msgData2, sig2);

      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const sys = await ethers.getSigner(SYSTEM);

      const tx = await slashing.connect(sys).slashValidator(
        validator.address,
        msg1,
        msg2,
        "Double signing COMMIT"
      );

      const receipt = await tx.wait();
      console.log("COMMIT message slashing succeeded, gas used:", receipt.gasUsed.toString());

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
    });
  });

  describe("Edge Cases", function () {
    it("should handle maximum message data size", async function () {
      console.log("\n=== Testing Large Message Data ===");

      // Create large data payloads (simulating real IBFT messages)
      const msgData1 = ethers.utils.hexConcat([
        ethers.utils.defaultAbiCoder.encode(["uint64", "uint64"], [160, 0]),
        ethers.utils.randomBytes(700), // Large payload
      ]);
      const msgData2 = ethers.utils.hexConcat([
        ethers.utils.defaultAbiCoder.encode(["uint64", "uint64"], [160, 0]),
        ethers.utils.randomBytes(700), // Large payload
      ]);

      console.log("msg1Data length:", ethers.utils.arrayify(msgData1).length);
      console.log("msg2Data length:", ethers.utils.arrayify(msgData2).length);

      const sig1 = await signIBFTMessage(validator2Wallet, msgData1);
      const sig2 = await signIBFTMessage(validator2Wallet, msgData2);

      const msg1 = createIBFTMessage(0, 160, 0, validator2.address, msgData1, sig1);
      const msg2 = createIBFTMessage(0, 160, 0, validator2.address, msgData2, sig2);

      await ethers.provider.send("hardhat_impersonateAccount", [SYSTEM]);
      const sys = await ethers.getSigner(SYSTEM);

      const tx = await slashing.connect(sys).slashValidator(
        validator2.address,
        msg1,
        msg2,
        "Large data test"
      );

      const receipt = await tx.wait();
      console.log("Large data slashing succeeded, gas used:", receipt.gasUsed.toString());

      await ethers.provider.send("hardhat_stopImpersonatingAccount", [SYSTEM]);
    });

    it("should only allow SYSTEM to call slashValidator", async function () {
      const msgData1 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [170, 0, ethers.utils.randomBytes(32)]
      );
      const msgData2 = ethers.utils.defaultAbiCoder.encode(
        ["uint64", "uint64", "bytes32"],
        [170, 0, ethers.utils.randomBytes(32)]
      );

      const sig1 = await signIBFTMessage(validatorWallet, msgData1);
      const sig2 = await signIBFTMessage(validatorWallet, msgData2);

      const msg1 = createIBFTMessage(0, 170, 0, validator.address, msgData1, sig1);
      const msg2 = createIBFTMessage(0, 170, 0, validator.address, msgData2, sig2);

      // Try calling from non-SYSTEM account
      await expect(
        slashing.connect(owner).slashValidator(validator.address, msg1, msg2, "Unauthorized call")
      ).to.be.revertedWithCustomError(slashing, "Unauthorized");

      console.log("Correctly rejected non-SYSTEM caller");
    });
  });
});
