var BSCBridge = artifacts.require("./BSCBridge.sol");
var ETHBridge = artifacts.require("./ETHBridge.sol");

module.exports = async function (deployer, network, accounts) {
  await deployer.deploy(
    BSCBridge,
    accounts[0],
    "1000",
    "100000000000000000000",
    "5000000000000000000",
    "100000000000000000000"
  );
  await deployer.deploy(
    ETHBridge,
    accounts[1],
    "1000",
    "100000000000000000000",
    "5000000000000000000",
    "100000000000000000000"
  );
};
