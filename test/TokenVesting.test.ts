import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { TokenVesting, MockERC20 } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("TokenVesting", function () {
  let tokenVesting: TokenVesting;
  let mockToken: MockERC20;
  let owner: SignerWithAddress;
  let beneficiary: SignerWithAddress;
  let creator: SignerWithAddress;

  const TOTAL_AMOUNT = ethers.parseEther("1000");
  const VESTING_DURATION = 365 * 24 * 60 * 60; // 1 year in seconds

  beforeEach(async function () {
    [owner, beneficiary, creator] = await ethers.getSigners();

    // Deploy TokenVesting contract
    const TokenVestingFactory = await ethers.getContractFactory("TokenVesting");
    tokenVesting = await TokenVestingFactory.deploy();

    // Deploy Mock ERC20 token
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    mockToken = await MockERC20Factory.deploy("Test Token", "TEST", ethers.parseEther("1000000"));

    // Mint tokens to creator
    await mockToken.mint(creator.address, TOTAL_AMOUNT * BigInt(10));
  });

  describe("Creating Vesting", function () {
    it("Should create a linear vesting schedule", async function () {
      const startTime = (await time.latest()) + 3600; // Start in 1 hour
      const endTime = startTime + VESTING_DURATION;

      // Approve tokens
      await mockToken.connect(creator).approve(await tokenVesting.getAddress(), TOTAL_AMOUNT);

      // Create vesting
      await expect(
        tokenVesting
          .connect(creator)
          .createVesting(
            await mockToken.getAddress(),
            beneficiary.address,
            TOTAL_AMOUNT,
            startTime,
            endTime,
            0, // LINEAR
            0  // DAILY (doesn't matter for linear)
          )
      )
        .to.emit(tokenVesting, "VestingCreated")
        .withArgs(0, creator.address, beneficiary.address, await mockToken.getAddress(), TOTAL_AMOUNT, startTime, endTime, 0, 0);

      // Check vesting details
      const vesting = await tokenVesting.getVesting(0);
      expect(vesting.creator).to.equal(creator.address);
      expect(vesting.beneficiary).to.equal(beneficiary.address);
      expect(vesting.totalAmount).to.equal(TOTAL_AMOUNT);
    });

    it("Should create a step-based vesting schedule", async function () {
      const startTime = (await time.latest()) + 3600;
      const endTime = startTime + VESTING_DURATION;

      await mockToken.connect(creator).approve(await tokenVesting.getAddress(), TOTAL_AMOUNT);

      await tokenVesting
        .connect(creator)
        .createVesting(
          await mockToken.getAddress(),
          beneficiary.address,
          TOTAL_AMOUNT,
          startTime,
          endTime,
          1, // STEP_BASED
          2  // MONTHLY
        );

      const vesting = await tokenVesting.getVesting(0);
      expect(vesting.releaseType).to.equal(1); // STEP_BASED
      expect(vesting.releaseFrequency).to.equal(2); // MONTHLY
    });

    it("Should revert if beneficiary is zero address", async function () {
      const startTime = (await time.latest()) + 3600;
      const endTime = startTime + VESTING_DURATION;

      await expect(
        tokenVesting
          .connect(creator)
          .createVesting(
            await mockToken.getAddress(),
            ethers.ZeroAddress, // Invalid beneficiary
            TOTAL_AMOUNT,
            startTime,
            endTime,
            0,
            0
          )
      ).to.be.revertedWithCustomError(tokenVesting, "InvalidBeneficiaryAddress");
    });

    it("Should revert if amount is zero", async function () {
      const startTime = (await time.latest()) + 3600;
      const endTime = startTime + VESTING_DURATION;

      await expect(
        tokenVesting
          .connect(creator)
          .createVesting(await mockToken.getAddress(), beneficiary.address, 0, startTime, endTime, 0, 0)
      ).to.be.revertedWithCustomError(tokenVesting, "InvalidAmount");
    });

    it("Should revert if start time is in the past", async function () {
      const startTime = (await time.latest()) - 100; // Past time
      const endTime = startTime + VESTING_DURATION;

      await expect(
        tokenVesting
          .connect(creator)
          .createVesting(await mockToken.getAddress(), beneficiary.address, TOTAL_AMOUNT, startTime, endTime, 0, 0)
      ).to.be.revertedWithCustomError(tokenVesting, "StartTimeMustBeFuture");
    });

    it("Should revert if end time is before start time", async function () {
      const startTime = (await time.latest()) + 3600;
      const endTime = startTime - 100; // Before start

      await expect(
        tokenVesting
          .connect(creator)
          .createVesting(await mockToken.getAddress(), beneficiary.address, TOTAL_AMOUNT, startTime, endTime, 0, 0)
      ).to.be.revertedWithCustomError(tokenVesting, "EndTimeMustBeAfterStart");
    });

    it("Should revert if vesting period is too short (< 60 seconds)", async function () {
      const startTime = (await time.latest()) + 100;
      const endTime = startTime + 30; // Only 30 seconds

      await expect(
        tokenVesting
          .connect(creator)
          .createVesting(await mockToken.getAddress(), beneficiary.address, TOTAL_AMOUNT, startTime, endTime, 0, 0)
      ).to.be.revertedWithCustomError(tokenVesting, "VestingPeriodTooShort");
    });
  });

  describe("Claiming Tokens - Linear Vesting", function () {
    let vestingId: number;
    let startTime: number;

    beforeEach(async function () {
      startTime = (await time.latest()) + 100;
      const endTime = startTime + VESTING_DURATION;

      await mockToken.connect(creator).approve(await tokenVesting.getAddress(), TOTAL_AMOUNT);

      await tokenVesting
        .connect(creator)
        .createVesting(await mockToken.getAddress(), beneficiary.address, TOTAL_AMOUNT, startTime, endTime, 0, 0);

      vestingId = 0;
    });

    it("Should return zero claimable before start time", async function () {
      const claimable = await tokenVesting.getClaimableAmount(vestingId);
      expect(claimable).to.equal(0);
    });

    it("Should allow claiming 50% after half the vesting period", async function () {
      await time.increaseTo(startTime + VESTING_DURATION / 2);

      const claimable = await tokenVesting.getClaimableAmount(vestingId);
      expect(claimable).to.be.closeTo(TOTAL_AMOUNT / BigInt(2), ethers.parseEther("1")); // Allow 1 token variance

      await expect(tokenVesting.connect(beneficiary).claim(vestingId))
        .to.emit(tokenVesting, "TokensClaimed");

      const balance = await mockToken.balanceOf(beneficiary.address);
      expect(balance).to.be.closeTo(TOTAL_AMOUNT / BigInt(2), ethers.parseEther("1"));
    });

    it("Should allow claiming 100% after vesting period ends", async function () {
      await time.increaseTo(startTime + VESTING_DURATION + 1);

      const claimable = await tokenVesting.getClaimableAmount(vestingId);
      expect(claimable).to.equal(TOTAL_AMOUNT);

      await tokenVesting.connect(beneficiary).claim(vestingId);

      const balance = await mockToken.balanceOf(beneficiary.address);
      expect(balance).to.equal(TOTAL_AMOUNT);

      const vesting = await tokenVesting.getVesting(vestingId);
      expect(vesting.status).to.equal(1); // COMPLETED
    });

    it("Should revert if non-beneficiary tries to claim", async function () {
      await time.increaseTo(startTime + VESTING_DURATION / 2);

      await expect(tokenVesting.connect(owner).claim(vestingId)).to.be.revertedWithCustomError(tokenVesting, "OnlyBeneficiary");
    });
  });

  describe("Claiming Tokens - Step-Based Vesting", function () {
    let vestingId: number;
    let startTime: number;

    beforeEach(async function () {
      startTime = (await time.latest()) + 100;
      const endTime = startTime + 30 * 24 * 60 * 60 * 12; // 12 months

      await mockToken.connect(creator).approve(await tokenVesting.getAddress(), TOTAL_AMOUNT);

      await tokenVesting
        .connect(creator)
        .createVesting(
          await mockToken.getAddress(),
          beneficiary.address,
          TOTAL_AMOUNT,
          startTime,
          endTime,
          1, // STEP_BASED
          2  // MONTHLY
        );

      vestingId = 0;
    });

    it("Should release tokens in monthly steps", async function () {
      // Move to 1 month after start
      await time.increaseTo(startTime + 30 * 24 * 60 * 60);

      const claimable = await tokenVesting.getClaimableAmount(vestingId);
      const expectedPerMonth = TOTAL_AMOUNT / BigInt(12);

      expect(claimable).to.be.closeTo(expectedPerMonth, ethers.parseEther("10"));
    });

    it("Should release all tokens after all steps completed", async function () {
      await time.increaseTo(startTime + 30 * 24 * 60 * 60 * 12 + 1);

      const claimable = await tokenVesting.getClaimableAmount(vestingId);
      expect(claimable).to.equal(TOTAL_AMOUNT);
    });
  });

  describe("Release Frequencies - Step-Based", function () {
    const testFrequency = async (frequency: number, intervalSeconds: number, numIntervals: number) => {
      const startTime = (await time.latest()) + 100;
      const endTime = startTime + intervalSeconds * numIntervals;

      await mockToken.connect(creator).approve(await tokenVesting.getAddress(), TOTAL_AMOUNT);

      await tokenVesting
        .connect(creator)
        .createVesting(
          await mockToken.getAddress(),
          beneficiary.address,
          TOTAL_AMOUNT,
          startTime,
          endTime,
          1, // STEP_BASED
          frequency
        );

      const vestingId = 0;

      // Test after 1 interval
      await time.increaseTo(startTime + intervalSeconds);
      const claimable1 = await tokenVesting.getClaimableAmount(vestingId);
      const expectedPerInterval = TOTAL_AMOUNT / BigInt(numIntervals);
      expect(claimable1).to.be.closeTo(expectedPerInterval, ethers.parseEther("10"));

      // Test after all intervals
      await time.increaseTo(endTime + 1);
      const claimableAll = await tokenVesting.getClaimableAmount(vestingId);
      expect(claimableAll).to.equal(TOTAL_AMOUNT);
    };

    it("Should work with MINUTELY frequency (60 seconds)", async function () {
      await testFrequency(0, 60, 10); // 10 minutes total
    });

    it("Should work with HOURLY frequency (3600 seconds)", async function () {
      await testFrequency(1, 3600, 24); // 24 hours total
    });

    it("Should work with DAILY frequency (86400 seconds)", async function () {
      await testFrequency(2, 86400, 30); // 30 days total
    });

    it("Should work with WEEKLY frequency (604800 seconds)", async function () {
      await testFrequency(3, 604800, 12); // 12 weeks total
    });

    it("Should work with MONTHLY frequency (2592000 seconds)", async function () {
      await testFrequency(4, 2592000, 12); // 12 months total
    });
  });

  describe("View Functions", function () {
    beforeEach(async function () {
      const startTime = (await time.latest()) + 100;
      const endTime = startTime + VESTING_DURATION;

      await mockToken.connect(creator).approve(await tokenVesting.getAddress(), TOTAL_AMOUNT * BigInt(2));

      await tokenVesting
        .connect(creator)
        .createVesting(await mockToken.getAddress(), beneficiary.address, TOTAL_AMOUNT, startTime, endTime, 0, 0);

      await tokenVesting
        .connect(creator)
        .createVesting(await mockToken.getAddress(), beneficiary.address, TOTAL_AMOUNT, startTime, endTime, 0, 0);
    });

    it("Should return vestings by creator", async function () {
      const creatorVestings = await tokenVesting.getVestingsByCreator(creator.address);
      expect(creatorVestings.length).to.equal(2);
      expect(creatorVestings[0]).to.equal(0);
      expect(creatorVestings[1]).to.equal(1);
    });

    it("Should return vestings by beneficiary", async function () {
      const beneficiaryVestings = await tokenVesting.getVestingsByBeneficiary(beneficiary.address);
      expect(beneficiaryVestings.length).to.equal(2);
    });

    it("Should return all vestings", async function () {
      const allVestings = await tokenVesting.getAllVestings();
      expect(allVestings.length).to.equal(2);
    });

    it("Should return total vesting count", async function () {
      const total = await tokenVesting.getTotalVestings();
      expect(total).to.equal(2);
    });
  });
});
