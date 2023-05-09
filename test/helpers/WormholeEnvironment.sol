// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "lib/wormhole/ethereum/contracts/relayer/relayProvider/RelayProviderImplementation.sol";
import "lib/wormhole/ethereum/contracts/relayer/relayProvider/RelayProviderSetup.sol";
import "lib/wormhole/ethereum/contracts/relayer/relayProvider/RelayProviderProxy.sol";
import "lib/wormhole/ethereum/contracts/relayer/coreRelayer/ForwardWrapper.sol";
import "lib/wormhole/ethereum/contracts/relayer/coreRelayer/CoreRelayer.sol";
import "lib/wormhole/ethereum/contracts/relayer/coreRelayer/CoreRelayerSetup.sol";
import "lib/wormhole/ethereum/contracts/relayer/create2Factory/Create2Factory.sol";

import "lib/wormhole/ethereum/contracts/interfaces/IWormhole.sol";

contract WormholeEnvironment is Test {
    string FORK_RPC_URL = vm.envString("ETHEREUM_MAINNET_RPC_URL");
    uint256 FORK_BLOCK_NUMBER = 17222591;
    uint256 private fork;

    // Wormhole Deploy Config
    bytes private constant SETUP_CONTRACT_SALT = abi.encodePacked("0xSetup");
    bytes private constant PROXY_CONTRACT_SALT = abi.encodePacked("0xGenericRelayer");
    uint16 private constant WH_GOVERNANCE_CHAIN_ID = 0x1;
    bytes32 private constant WH_GOVERNANCE_CONTRACT = bytes32(uint256(0x4));
    uint256 private constant WH_CHAIN_ID = 0x2;

    // Wormhole Contracts
    IWormhole wormhole = IWormhole(0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B);
    CoreRelayer wormholeCoreRelayer;

    constructor() {
        fork = vm.createFork(FORK_RPC_URL, FORK_BLOCK_NUMBER);
        vm.label(address(wormhole), "WHCore");
    }

    modifier withWormhole() {
        uint256 activeFork = vm.activeFork();
        vm.selectFork(fork);
        assertEq(vm.activeFork(), fork);
        _;
        vm.selectFork(activeFork);
        assertEq(vm.activeFork(), activeFork);
    }

    function _setUpWormholeEnvironment() internal withWormhole {
        Create2Factory factory = new Create2Factory();
        vm.label(address(factory), "WHCreate2Factory");

        // Deploy Default Relayer Provider
        RelayProviderImplementation relayProviderImplementation = new RelayProviderImplementation();
        vm.label(address(relayProviderImplementation), "WHRelayProviderImpl");

        // Deploy Relayer Provider Setup
        RelayProviderSetup relayProviderSetup = new RelayProviderSetup();
        vm.label(address(relayProviderSetup), "WHRelayProviderSetup");

        // Deploy RelayProvider Proxy
        bytes memory setupCalldata =
            abi.encodeCall(relayProviderSetup.setup, (address(relayProviderImplementation), uint16(block.chainid)));
        RelayProviderProxy relayProvider = new RelayProviderProxy(address(relayProviderSetup), setupCalldata);
        vm.label(address(relayProvider), "WHRelayProvider");

        // Deploy Forward Wrapper
        address coreRelayerCounterfactualAddress = factory.computeProxyAddress(address(this), PROXY_CONTRACT_SALT);
        ForwardWrapper forwardWrapper = new ForwardWrapper(coreRelayerCounterfactualAddress, address(wormhole));
        vm.label(address(forwardWrapper), "whforwardwrapper");

        // Deploy Core Relayer Implementation
        CoreRelayer coreRelayerImplementation = new CoreRelayer(address(forwardWrapper));
        vm.label(address(coreRelayerImplementation), "WHCoreRelayerImpl");

        // Deploy Core Relayer Setup
        CoreRelayerSetup coreRelayerSetup =
            CoreRelayerSetup(factory.create2(SETUP_CONTRACT_SALT, vm.getCode("CoreRelayerSetup.sol")));
        vm.label(address(coreRelayerSetup), "wormholeCoreRelayerSetup");

        // Deploy CoreRelayerProxy
        setupCalldata = abi.encodeCall(
            coreRelayerSetup.setup,
            (
                address(coreRelayerImplementation),
                uint16(block.chainid),
                address(wormhole),
                address(relayProvider),
                WH_GOVERNANCE_CHAIN_ID,
                WH_GOVERNANCE_CONTRACT,
                WH_CHAIN_ID
            )
        );
        wormholeCoreRelayer =
            CoreRelayer(factory.create2Proxy(PROXY_CONTRACT_SALT, address(coreRelayerSetup), setupCalldata));
        vm.label(address(wormholeCoreRelayer), "WHCoreRelayer");
    }
}
