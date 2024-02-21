//SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Assertions } from "./utils/Assertions/Assertions.sol";
import { console } from "forge-std/console.sol";
import { AsyncSynthVault, SyncSynthVault } from "../src/AsyncSynthVault.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestBase is Assertions {
    // OWNER ACTIONS //

    function open(AsyncSynthVault vault, int256 performanceInBips) public {
        vm.assume(performanceInBips > -10_000 && performanceInBips < 10_000);
        int256 lastAssetAmount = int256(vault.totalAssets());
        int256 performance = lastAssetAmount * performanceInBips;
        int256 toSendBack = performance / bipsDivider + lastAssetAmount;
        address owner = vault.owner();
        deal(owner, type(uint256).max);
        _approveVaults(owner);
        _dealAsset(vault.asset(), owner, uint256(toSendBack));
        vm.prank(owner);
        vault.open(uint256(toSendBack));
    }

    function close(AsyncSynthVault vault) public {
        address owner = vault.owner();
        vm.prank(owner);
        vault.close();
    }

    function closeRevertLocked(AsyncSynthVault vault) public {
        address owner = vault.owner();
        vm.startPrank(owner);
        vm.expectRevert(SyncSynthVault.VaultIsLocked.selector);
        vault.close();
        vm.stopPrank();
    }

    function closeRevertUnauthorized(AsyncSynthVault vault) public {
        address user = users[0].addr;
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                user
            )
        );
        vault.close();
        vm.stopPrank();
    }

    function closeVaults() public {
        close(vaultUSDC);
        close(vaultWSTETH);
        close(vaultWBTC);
    }

    function pause(AsyncSynthVault vault) public {
        address owner = vault.owner();
        vm.prank(owner);
        vault.pause();
    }

    function unpause(AsyncSynthVault vault) public {
        address owner = vault.owner();
        vm.prank(owner);
        vault.unpause();
    }

    // USER INFO //
    function vaultAssetBalanceOf(
        IERC4626 vault,
        address user
    ) public view returns (uint256) {
        return IERC20(vault.asset()).balanceOf(user);
    }

    // USERS ACTIONS //

    function mint(AsyncSynthVault vault, VmSafe.Wallet memory user) public {
        mint(vault, user, USDC.balanceOf(user.addr));
    }

    function deposit(AsyncSynthVault vault, VmSafe.Wallet memory user) public {
        deposit(vault, user, USDC.balanceOf(user.addr));
    }

    function depositRevert(
        AsyncSynthVault vault,
        VmSafe.Wallet memory user,
        bytes4 selector
    ) public {
        depositRevert(vault, user, USDC.balanceOf(user.addr), selector);
    }

    function withdraw(AsyncSynthVault vault, VmSafe.Wallet memory user) public {
        withdraw(vault, user, USDC.balanceOf(user.addr));
    }

    function redeem(AsyncSynthVault vault, VmSafe.Wallet memory user) public {
        redeem(vault, user, vault.balanceOf(user.addr));
    }

    function mint(
        AsyncSynthVault vault,
        VmSafe.Wallet memory user,
        uint256 amount
    ) public {
        vm.startPrank(user.addr);
        vault.mint(amount, user.addr);
    }

    function deposit(
        AsyncSynthVault vault,
        VmSafe.Wallet memory user,
        uint256 amount
    ) private {
        vm.startPrank(user.addr);
        vault.deposit(amount, user.addr);
    }

    function depositRevert(
        AsyncSynthVault vault,
        VmSafe.Wallet memory user,
        uint256 amount,
        bytes4 selector
    ) public {
        vm.startPrank(user.addr);
        vm.expectRevert(selector);
        vault.deposit(amount, user.addr);
    }

    function depositRevert2(
        AsyncSynthVault vault,
        VmSafe.Wallet memory user,
        uint256 amount,
        bytes calldata revertData
    ) public {
        vm.startPrank(user.addr);
        vm.expectRevert(revertData);
        vault.deposit(amount, user.addr);
    }

    function withdraw(
        AsyncSynthVault vault,
        VmSafe.Wallet memory user,
        uint256 amount
    ) public {
        vm.startPrank(user.addr);
        vault.withdraw(amount, user.addr, user.addr);
    }

    function redeem(
        AsyncSynthVault vault,
        VmSafe.Wallet memory user,
        uint256 shares
    ) public {
        vm.startPrank(user.addr);
        vault.redeem(shares, user.addr, user.addr);
    }

    function requestDeposit(
        AsyncSynthVault vault,
        VmSafe.Wallet memory user,
        uint256 amount
    ) public {
        vm.startPrank(user.addr);
        vault.requestDeposit(
            amount,
            user.addr,
            user.addr,
            ""
        );
    }

    function requestRedeem(
        AsyncSynthVault vault,
        VmSafe.Wallet memory user,
        uint256 amount
    ) public {
        vm.startPrank(user.addr);
        vault.requestRedeem(
            amount,
            user.addr,
            user.addr,
            "" // todo
        );
    }

    function decreaseDepositRequest(
        AsyncSynthVault vault,
        VmSafe.Wallet memory user,
        uint256 amount
    ) public {
        vm.startPrank(user.addr);
        vault.decreaseDepositRequest(
            amount,
            user.addr
        );
    }

    function decreaseRedeemRequest(
        AsyncSynthVault vault,
        VmSafe.Wallet memory user,
        uint256 amount
    ) public {
        decreaseRedeemRequest(vault, user, user, amount);
    }

    function decreaseRedeemRequest(
        AsyncSynthVault vault,
        VmSafe.Wallet memory user,
        VmSafe.Wallet memory receiver,
        uint256 amount
    ) public {
        vm.startPrank(user.addr);
        vault.decreaseRedeemRequest(
            amount,
            receiver.addr
        );
    }

    // USERS CONFIGURATION //

    function usersDealApproveAndDeposit(uint256 userMax) public {
        userMax = userMax > users.length ? users.length : userMax;
        usersDealApprove(userMax);
        usersDeposit(userMax);
    }

    function usersDealApproveAndRequestDeposit(uint256 userMax) public {
        userMax = userMax > users.length ? users.length : userMax;
        usersDealApprove(userMax);
        usersRequestDeposit(userMax);
    }

    function usersDealApproveAndRequestRedeem(uint256 userMax) public {
        userMax = userMax > users.length ? users.length : userMax;
        usersDealApprove(userMax);
        usersRequestRedeem(userMax);
    }

    function usersDeposit(uint256 userMax) public {
        userMax = userMax > users.length ? users.length : userMax;
        for (uint256 i = 0; i < userMax; i++) {
            _depositInVaults(users[i].addr);
        }
    }

    function usersRequestDeposit(uint256 userMax) public {
        userMax = userMax > users.length ? users.length : userMax;
        for (uint256 i = 0; i < userMax; i++)
            _requestDepositInVaults(users[i].addr);
    }

    function usersRequestRedeem(uint256 userMax) public {
        userMax = userMax > users.length ? users.length : userMax;
        for (uint256 i = 0; i < userMax; i++)
            _requestRedeemInVaults(users[i].addr);
    }

    function usersDealApprove(uint256 userMax) public {
        userMax = userMax > users.length ? users.length : userMax;
        for (uint256 i = 0; i < userMax; i++) {
            deal(users[i].addr, type(uint256).max);
            _approveVaults(users[i].addr);
            _dealAssets(users[i].addr);
        }
    }

    function _approveVaults(address owner) internal {
        vm.startPrank(owner);
        USDC.approve(address(vaultUSDC), type(uint256).max);
        WSTETH.approve(address(vaultWSTETH), type(uint256).max);
        WBTC.approve(address(vaultWBTC), type(uint256).max);
        vm.stopPrank();
    }

    function _dealAssets(address owner) internal {
        _dealAsset(address(WSTETH), owner, 100 * 10 ** WSTETH.decimals());
        _dealAsset(address(WBTC), owner, 10 * 10 ** WBTC.decimals());
        _dealAsset(address(USDC), owner, 1000 * 10 ** USDC.decimals());
    }

    function _dealAsset(address asset, address owner, uint256 amount) internal {
        if (asset == address(USDC)) {
            vm.startPrank(USDC_WHALE);
            USDC.transfer(owner, amount);
            vm.stopPrank();
        } else {
            deal(asset, owner, amount);
        }
    }

    function _depositInVaults(address owner) internal {
        vm.startPrank(owner);
        uint256 usdcDeposit = USDC.balanceOf(owner) / 4;
        vaultUSDC.deposit(usdcDeposit, owner);
        uint256 wstethDeposit = WSTETH.balanceOf(owner) / 4;
        vaultWSTETH.deposit(wstethDeposit, owner);
        uint256 wbtcDeposit = WBTC.balanceOf(owner) / 4;
        vaultWBTC.deposit(wbtcDeposit, owner);
        vm.stopPrank();
    }

    function _requestDepositInVaults(address owner) internal {
        vm.startPrank(owner);
        console.log("USDC deposit request amount:", USDC.balanceOf(owner)/4);
        vaultUSDC.requestDeposit(USDC.balanceOf(owner)/4, owner, owner, "");
        console.log("WSTETH deposit request amount", WSTETH.balanceOf(owner)/4);
        vaultWSTETH.requestDeposit(WSTETH.balanceOf(owner)/4, owner, owner, "");
        console.log("WBTC deposit request amount", WBTC.balanceOf(owner)/4);
        vaultWBTC.requestDeposit(WBTC.balanceOf(owner)/4, owner, owner, "");
        vm.stopPrank();
    }

    function _requestRedeemInVaults(address owner) internal {
        vm.startPrank(owner);
        console.log("USDC redeem request amount", vaultUSDC.balanceOf(owner));
        vaultUSDC.requestRedeem(vaultUSDC.balanceOf(owner), owner, owner, "");
        console.log("WSTETH redeem request amount", vaultWSTETH.balanceOf(owner));
        vaultWSTETH.requestRedeem(vaultWSTETH.balanceOf(owner), owner, owner, "");
        console.log("WBTC redeem request amount", vaultWBTC.balanceOf(owner));
        vaultWBTC.requestRedeem(vaultWBTC.balanceOf(owner), owner, owner, "");
        vm.stopPrank();
    }
}
