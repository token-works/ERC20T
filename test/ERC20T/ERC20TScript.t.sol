// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20TScriptConfig} from "../../script/ERC20T/DeployERC20T.s.sol";

contract ERC20TScriptConfigHarness is ERC20TScriptConfig {
    function readConfig(uint256 lpSupply) external view returns (ERC20T.Config memory) {
        return _readTokenConfig(lpSupply);
    }
}

/// @notice Validate environment values before narrowing tax rates and decay intervals.
contract ERC20TScriptTest is Test {
    ERC20TScriptConfigHarness harness;

    function setUp() public {
        harness = new ERC20TScriptConfigHarness();
        // Supply every value the helper reads; these tests do not depend on the caller's environment.
        vm.setEnv("TOKEN_NAME", "Script Token");
        vm.setEnv("TOKEN_SYMBOL", "SCRIPT");
        vm.setEnv("TOKEN_SUPPLY", "1000000000000000000000");
        vm.setEnv("TOKEN_OWNER", "0x0000000000000000000000000000000000000011");
        vm.setEnv("ERC20T_HOOK", "0x0000000000000000000000000000000000000022");
        vm.setEnv("QUOTE_TOKEN", "0x0000000000000000000000000000000000000033");
        vm.setEnv("POSITION_MANAGER", "0x0000000000000000000000000000000000000044");
        vm.setEnv("PERMIT2", "0x0000000000000000000000000000000000000055");
        vm.setEnv("FEE_RECIPIENT", "0x0000000000000000000000000000000000000066");
        vm.setEnv("FEE_DECAY_RECIPIENT", "0x0000000000000000000000000000000000000000");
        vm.setEnv("TAX_BPS", "100");
        vm.setEnv("LAUNCH_TAX_BPS", "0");
        vm.setEnv("TAX_DECAY_INTERVAL_SECONDS", "0");
    }

    // Keep environment mutations in one test: Foundry runs separate tests concurrently,
    // while vm.setEnv affects the process-wide environment.
    function test_scriptValidatesRawTaxBoundsAndPreservesConfiguration() public {
        uint256[3] memory invalid = [uint256(0), 29, 501];
        for (uint256 i; i < invalid.length; ++i) {
            vm.setEnv("TAX_BPS", vm.toString(invalid[i]));
            vm.expectRevert(abi.encodeWithSelector(ERC20TScriptConfig.InvalidTaxBps.selector, invalid[i]));
            harness.readConfig(800 ether);
        }

        uint256 raw = uint256(type(uint16).max) + 31;
        assertEq(uint16(raw), 30);
        vm.setEnv("TAX_BPS", vm.toString(raw));
        vm.expectRevert(abi.encodeWithSelector(ERC20TScriptConfig.InvalidTaxBps.selector, raw));
        harness.readConfig(800 ether);

        uint16[2] memory accepted = [uint16(30), 500];
        for (uint256 i; i < accepted.length; ++i) {
            vm.setEnv("TAX_BPS", vm.toString(accepted[i]));
            ERC20T.Config memory config = harness.readConfig(800 ether);
            assertEq(config.taxBps, accepted[i]);
            assertEq(config.name, "Script Token");
            assertEq(config.symbol, "SCRIPT");
            assertEq(config.supply, 1_000 ether);
            assertEq(config.lpSupply, 800 ether);
            assertEq(config.owner, address(0x11));
            assertEq(config.hook, address(0x22));
            assertEq(config.quoteToken, address(0x33));
            assertEq(address(config.positionManager), address(0x44));
            assertEq(address(config.permit2), address(0x55));
            assertEq(config.feeRecipient, address(0x66));
            assertEq(config.feeDecayRecipient, address(0)); // Token initialization copies feeRecipient.
            assertEq(config.launchTaxBps, 0);
            assertEq(config.taxDecayIntervalSeconds, 0);
        }

        vm.setEnv("TAX_BPS", "100");
        // Selecting an interval automatically selects the fixed 99% starting rate.
        vm.setEnv("TAX_DECAY_INTERVAL_SECONDS", "60");
        ERC20T.Config memory configured = harness.readConfig(800 ether);
        assertEq(configured.taxBps, 100);
        assertEq(configured.launchTaxBps, 9900);
        assertEq(configured.taxDecayIntervalSeconds, 60);

        vm.setEnv("FEE_DECAY_RECIPIENT", "0x0000000000000000000000000000000000000077");
        configured = harness.readConfig(800 ether);
        assertEq(configured.feeRecipient, address(0x66));
        assertEq(configured.feeDecayRecipient, address(0x77));
        assertEq(configured.launchTaxBps, 9900);

        // The legacy explicit starting-rate variable accepts only 99% when enabled.
        vm.setEnv("LAUNCH_TAX_BPS", "9900");
        vm.setEnv("TAX_DECAY_INTERVAL_SECONDS", vm.toString(type(uint32).max));
        configured = harness.readConfig(800 ether);
        assertEq(configured.launchTaxBps, 9900);
        assertEq(configured.taxDecayIntervalSeconds, type(uint32).max);

        _assertInvalidTaxDecay(9900, 0);
        _assertInvalidTaxDecay(400, 60);
        _assertInvalidTaxDecay(99, 60);
        _assertInvalidTaxDecay(29, 60);
        _assertInvalidTaxDecay(501, 60);
        _assertInvalidTaxDecay(9899, 60);
        _assertInvalidTaxDecay(9901, 60);
        _assertInvalidTaxDecay(10000, 60);

        // Each overflow would truncate to a valid value if narrowing happened before validation.
        uint256 overflowingLaunchTax = uint256(type(uint16).max) + 9901;
        assertEq(uint16(overflowingLaunchTax), 9900);
        _assertInvalidTaxDecay(overflowingLaunchTax, 60);
        uint256 overflowingInterval = uint256(type(uint32).max) + 61;
        assertEq(uint32(overflowingInterval), 60);
        _assertInvalidTaxDecay(9900, overflowingInterval);
        _assertInvalidTaxDecay(0, overflowingInterval);
    }

    function _assertInvalidTaxDecay(uint256 launchTaxBps, uint256 intervalSeconds) private {
        vm.setEnv("LAUNCH_TAX_BPS", vm.toString(launchTaxBps));
        vm.setEnv("TAX_DECAY_INTERVAL_SECONDS", vm.toString(intervalSeconds));
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20TScriptConfig.InvalidTaxDecayConfiguration.selector, launchTaxBps, intervalSeconds
            )
        );
        harness.readConfig(800 ether);
    }
}
