import { ethers } from "hardhat";
import { readFile } from "fs/promises";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  TokenListingProposal,
  MasterChefProposal,
  ERC20,
} from "../typechain-types";
import { BigNumber } from "ethers";
import { expect } from "chai";
import { impersonateAccount } from "@nomicfoundation/hardhat-network-helpers";

const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";

async function getAbi(path: string) {
  const data = await readFile(path, "utf8");
  const abi = new ethers.utils.Interface(JSON.parse(data));
  return abi;
}

async function getContract(pathToAbi: string, deployedAddress: string) {
  const abi = await getAbi(pathToAbi);
  const prov = new ethers.providers.JsonRpcProvider("http://localhost:8545");
  return new ethers.Contract(deployedAddress, abi, prov);
}

// https://ethereum.org/en/developers/tutorials/downsizing-contracts-to-fight-the-contract-size-limit/
describe("MasterChefProposal", function () {
  let USDC: ERC20;
  let signers: SignerWithAddress[];
  let Chef: MasterChefProposal;
  let Proposal: TokenListingProposal;

  before(async () => {
    signers = await ethers.getSigners();
    USDC = await ethers.getContractAt("ERC20", USDC_ADDRESS);

    const usdc = await getContract("./test/ABI/USDC.json", USDC_ADDRESS);
    const usdcOwner = await usdc.owner();

    await impersonateAccount(usdcOwner);
    const impersonatedSignerUSDC = await ethers.getSigner(usdcOwner);
    const toMint = BigNumber.from(10).pow(6).mul(300000);
    let tx = {
      to: impersonatedSignerUSDC.address,
      value: ethers.utils.parseEther("100"),
    };
    signers[1].sendTransaction(tx);

    await usdc.connect(impersonatedSignerUSDC).updateMasterMinter(usdcOwner);
    await usdc
      .connect(impersonatedSignerUSDC)
      .configureMinter(usdcOwner, ethers.constants.MaxUint256);
    console.log(
      "USDC balance before: %s",
      await usdc.balanceOf(signers[0].address)
    );
    await usdc.connect(impersonatedSignerUSDC).mint(signers[0].address, toMint);
    console.log(
      "USDC balance after: %s",
      await usdc.balanceOf(signers[0].address)
    );
  });

  it("Deploy MasterChefProposal", async () => {
    const MasterChef = await ethers.getContractFactory("MasterChefProposal");
    const chef = await MasterChef.deploy();
    await chef.deployed();
    expect(chef.address).to.not.eq(ethers.constants.AddressZero);
    Chef = chef as MasterChefProposal;
    console.log("MasterChefProposal address: %s", chef.address);
  });

  it("Deploy new TokenListingProposal", async () => {
    const incentiveTokenAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    const incentiveTokenAmount = 100000000; // ethers.utils.parseEther("1000");
    const destributionPeriod = 100000; // 30 * 24 * 60 * 60; // 30 days
    const proposalDeadline = 100000; // Math.floor(Date.now() / 1000) + 2 * 24 * 60 * 60; // 2 days from now
    // const asxFee = 15000000;
    const adminAddress = await signers[1].address;

    await USDC.transfer(Chef.address, ethers.utils.parseUnits("1000", 6));
    // console.log("Before signer[0] Deploy: %s", await USDC.balanceOf(signers[0].address));
    // // console.log("Before on Proposal Deploy: %s", await USDC.balanceOf(Proposal.address));
    // console.log("Before on MasterChef Deploy: %s", await USDC.balanceOf(Chef.address));

    const proposalAddress = await Chef.callStatic.deployProposal(
      incentiveTokenAddress,
      incentiveTokenAmount,
      destributionPeriod,
      proposalDeadline,
      adminAddress
    );

    console.log("proposalAddress: ", proposalAddress);
    //  console.log("After Deploy: %s", await USDC.balanceOf(signers[0].address));
    //  console.log("After on Proposal Deploy: %s", await USDC.balanceOf(proposalAddress));
    //  console.log("After on MasterChef Deploy: %s", await USDC.balanceOf(Chef.address));
    Proposal = await ethers.getContractAt(
      "TokenListingProposal",
      proposalAddress
    );
  });

  it("Stake on TokenListingProposal", async () => {
    const _amountToStake = 1000000000;
    const _lockPeriod = 100000;

    await USDC.connect(signers[0].address).approve(
      Proposal.address,
      10000000000000
    );
    console.log(
      "alllow ",
      await USDC.connect(signers[0].address).allowance(
        signers[0].address,
        Proposal.address
      )
    );
    // console.log("USDC balance before Stake: %s", await USDC.balanceOf(signers[0].address));
    // console.log("USDC balance on Proposal before Stake: %s", await USDC.balanceOf(Proposal.address));
    // console.log("USDC balance on MasterChef before Stake: %s", await USDC.balanceOf(Chef.address));
    await Proposal.stakeOnProposal(_amountToStake, _lockPeriod);
    // console.log("USDC balance after Stake: %s", await USDC.balanceOf(signers[0].address));
    // console.log("USDC balance on Proposal after Stake: %s", await USDC.balanceOf(Proposal.address));
    // console.log("USDC balance on MasterChef after Stake: %s", await USDC.balanceOf(Chef.address));
  });

  it("Claim rewards from TokenListingProposal", async () => {
    await ethers.provider.send("evm_increaseTime", [3600 * 24 * 5]);
    // console.log("USDC balance before claimRewards: %s", await USDC.balanceOf(signers[0].address));
    // console.log("USDC balance on Proposal before claimRewards: %s", await USDC.balanceOf(Proposal.address));
    // console.log("USDC balance on MasterChef before claimRewards: %s", await USDC.balanceOf(Chef.address));
    await Proposal.claimRewards();
    // console.log("USDC balance after claimRewards: %s", await USDC.balanceOf(signers[0].address));
    // console.log("USDC balance on Proposal after claimRewards: %s", await USDC.balanceOf(Proposal.address));
    // console.log("USDC balance on MasterChef after claimRewards: %s", await USDC.balanceOf(Chef.address));
  });
});
