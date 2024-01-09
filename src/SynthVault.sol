//SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {IERC7540, IERC165, IERC7540Redeem} from "./interfaces/IERC7540.sol";
import {
    Ownable,
    Ownable2Step
} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {
    IERC20,
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    ERC20Pausable,
    Pausable,
    ERC20
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20Permit} from
    "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SynthVaultRequestReceipt, SafeERC20} from "./SynthVaultRequestReceipt.sol";
import {IPermit2, ISignatureTransfer} from "permit2/src/interfaces/IPermit2.sol";

struct Permit2Params {
    uint256 amount;
    uint256 nonce;
    uint256 deadline;
    address token;
    bytes signature;
}

struct Epoch {
    uint256 totalDeposits;
    uint256 totalRequests;
    mapping(address => uint256) deposits;
    mapping(address => uint256) withdrawals;
}

contract SynthVault is IERC7540, ERC20Pausable, Ownable2Step, ERC20Permit {

    /*
     ######
      LIBS
     ######
    */

    /**
     * @dev The `Math` lib is only used for `mulDiv` operations.
     */
    using Math for uint256;

    /**
     * @dev The `SafeERC20` lib is only used for `safeTransfer` and
     * `safeTransferFrom` operations.
     */
    using SafeERC20 for IERC20;

    /*
     ########
      EVENTS
     ########
    */

    /**
     * @dev Emitted when an epoch starts.
     * @param timestamp The block timestamp of the epoch start.
     * @param lastSavedBalance The `lastSavedBalance` when the vault start.
     * @param totalShares The total amount of shares when the vault start.
     */
    event EpochStart(
        uint256 indexed timestamp, uint256 lastSavedBalance, uint256 totalShares
    );

    /**
     * @dev Emitted when an epoch ends.
     * @param timestamp The block timestamp of the epoch end.
     * @param lastSavedBalance The `lastSavedBalance` when the vault end.
     * @param returnedAssets The total amount of underlying assets returned to
     * the vault before collecting fees.
     * @param fees The amount of fees collected.
     * @param totalShares The total amount of shares when the vault end.
     */
    event EpochEnd(
        uint256 indexed timestamp,
        uint256 lastSavedBalance,
        uint256 returnedAssets,
        uint256 fees,
        uint256 totalShares
    );

    /**
     * @dev Emitted when fees are changed.
     * @param oldFees The old fees.
     * @param newFees The new fees.
     */
    event FeesChanged(uint16 oldFees, uint16 newFees);

    /*
     ########
      ERRORS
     ########
    */

    /**
     * @dev The rules doesn't allow the perf fees to be higher than 30.00%.
     */
    error FeesTooHigh();

    /**
     * @dev Attempted to deposit more underlying assets than the max amount for
     * `receiver`.
     */
    error ERC4626ExceededMaxDeposit(
        address receiver, uint256 assets, uint256 max
    );

    /**
     * @dev Attempted to redeem more shares than the max amount for `receiver`.
     */
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

    /*
     ####################################
      GENERAL PERMIT2 RELATED ATTRIBUTES
     ####################################
    */

    // The canonical permit2 contract.
    IPermit2 public immutable permit2;

    /*
     #####################################
      AMPHOR SYNTHETIC RELATED ATTRIBUTES
     #####################################
    */

    /**
     * @dev The perf fees applied on the positive yield.
     * @return Amount of the perf fees applied on the positive yield.
     */
    uint16 public feesInBps;

    IERC20 internal immutable _asset;
    uint256 public epochNonce = 1; // in order to start at epoch 1, otherwise users might try to claim epoch -1 requests
    uint256[] public globalAssets; // withdrawals requests that has been processed && waiting for claim/deposit
    uint256[] public globalShares; // deposits requests that has been processed && waiting for claim/withdraw
    uint256 public totalAssets; // total working assets (in the strategy), not including pending withdrawals money

    SynthVaultRequestReceipt public depositRequestReceipt; // deposits requests tokens
    SynthVaultRequestReceipt public withdrawRequestReceipt; // withdrawals requests tokens

    Epoch[] public epochs;

    /*
     ############################
      AMPHOR SYNTHETIC FUNCTIONS
     ############################
    */

    constructor(
        ERC20 underlying,
        string memory name,
        string memory symbol,
        string memory depositRequestReceiptName,
        string memory depositRequestReceiptSymbol,
        string memory withdrawRequestReceiptName,
        string memory withdrawRequestReceiptSymbol,
        IPermit2 _permit2
    ) ERC20(name, symbol) Ownable(_msgSender()) ERC20Permit(name) {
        _asset = IERC20(underlying);
        permit2 = _permit2;
        depositRequestReceipt = new SynthVaultRequestReceipt(underlying, depositRequestReceiptName, depositRequestReceiptSymbol);
        withdrawRequestReceipt = new SynthVaultRequestReceipt(underlying, withdrawRequestReceiptName, withdrawRequestReceiptSymbol);
    }

    function requestDeposit(uint256 assets, address receiver, address owner) public whenNotPaused {
        // Claim not claimed request (if any)
        uint256 lastRequestId = depositRequestReceipt.lastRequestId(owner);
        uint256 lastRequestBalance = depositRequestReceipt.balanceOf(owner, lastRequestId);
        if (lastRequestBalance > 0 && lastRequestId != epochNonce) // We don't want to call _deposit for nothing and we don't want to cancel a current request if the user just want to increase it.
            deposit(owner, owner, lastRequestId, lastRequestBalance);

        // Create a new request
        depositRequestReceipt.deposit(epochNonce, assets, receiver, owner);
        depositRequestReceipt.setLastRequest(owner, epochNonce);

        emit DepositRequest(receiver, owner, epochNonce, _msgSender(), assets);
    }

    function withdrawDepositRequest(uint256 assets, address receiver, address owner) external whenNotPaused {
        depositRequestReceipt.withdraw(epochNonce, assets, receiver, owner);

        //TODO emit event ?
    }

    function pendingDepositRequest(address owner) external view returns (uint256 assets) {
        return depositRequestReceipt.balanceOf(owner, epochNonce);
    }

    function requestRedeem(uint256 shares, address receiver, address owner, bytes memory) external whenNotPaused {
        // Claim not claimed request (if any)
        uint256 lastRequestId = withdrawRequestReceipt.lastRequestId(owner);
        uint256 lastRequestBalance = withdrawRequestReceipt.balanceOf(owner, lastRequestId);
        if (lastRequestBalance > 0 && lastRequestId != epochNonce) // We don't want to call _redeem for nothing and we don't want to cancel a current request if the user just want to increase it.
            redeem(owner, receiver, lastRequestId, lastRequestBalance);

        // Create a new request
        withdrawRequestReceipt.deposit(epochNonce, shares, receiver, owner);
        withdrawRequestReceipt.setLastRequest(owner, epochNonce);

        emit RedeemRequest(receiver, owner, epochNonce, _msgSender(), shares);
    }

    function withdrawRedeemRequest(uint256 shares, address receiver, address owner) external whenNotPaused {
        withdrawRequestReceipt.withdraw(epochNonce, shares, receiver, owner);

        //TODO emit event ?
    }

    function pendingRedeemRequest(address owner) external view returns (uint256 shares) {
        return withdrawRequestReceipt.balanceOf(owner, epochNonce);
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC7540Redeem).interfaceId;
    }

    /*
     ####################################
      GENERAL ERC-4626 RELATED FUNCTIONS
     ####################################
    */

    function asset() public view returns (address) {
        return address(_asset);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /*
     @dev The `maxDeposit` function is used to get the max amount of underlying
        assets that can be deposited for `owner`.
     @param owner The address of the account for which we want to know the max
     amount of underlying assets that can be deposited.
     @return The max amount of underlying assets that can be deposited for
     `owner`.
    */
    function maxDeposit(address owner) public view returns (uint256) {
        return depositRequestReceipt.balanceOf(owner, epochNonce - 1);
    }

    // TODO: implement this correclty if possible (it's not possible to know the max mintable shares)
    function maxMint(address) public pure returns (uint256) {
        return 0;
    }

    // TODO: implement this correclty if possible (it's not possible to know the max withdrawable assets)
    function maxWithdraw(address) public pure returns (uint256) {
        return 0;
    }

    /*
     @dev The `maxRedeem` function is used to get the max amount of shares that
        can be redeemed for `owner`.
     @param owner The address of the account for which we want to know the max
     amount of shares that can be redeemed.
     @return The max amount of shares that can be redeemed for `owner`.
    */
    function maxRedeem(address owner) public view returns (uint256) {
        return withdrawRequestReceipt.balanceOf(owner, epochNonce - 1);
    }

    /* 
     @dev The `previewDeposit` function is used to preview the amount of shares
        that would be minted for `assets` amount of underlying assets for the last
        epoch.
     @param assets The amount of underlying assets for which we want to know the
     amount of shares that would be minted.
     @return The amount of shares that would be minted for `assets` amount of
     underlying assets.
    */
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertDepositReceiptToShares(epochNonce - 1, assets, Math.Rounding.Floor);
    }

    /* 
     @dev The `previewMint` function is used to preview the amount of shares
        that would be minted for `shares` amount of shares for a specified epoch.
     @param epochId The epoch for which we want to know the amount of shares
        that would be minted.
     @param assets The amount of assets for which we want to know the amount of
        shares that would be minted.
     @return The amount of shares that would be minted for `shares` amount of
     shares.
    */
    function previewDeposit(uint256 epochId, uint256 assets) public view returns (uint256) {
        return _convertDepositReceiptToShares(epochId, assets, Math.Rounding.Floor);
    }

    // TODO implement this correctly if possible (it's not possible to know the mintable shares)
    function previewMint(uint256) public pure returns (uint256) {
        return 0;
    }

    //TODO implement this correctly if possible (it's not possible to know the withdrawable assets)
    function previewWithdraw(uint256) public pure returns (uint256) {
        return 0;
    }

    /* 
     @dev The `previewRedeem` function is used to preview the amount of assets
        that would be redeemed for `shares` amount of shares for the last epoch.
     @param shares The amount of shares for which we want to know the amount of
     assets that would be redeemed.
     @return The amount of assets that would be redeemed for `shares` amount of
     shares.
    */
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertWithdrawReceiptToAssets(epochNonce - 1, shares, Math.Rounding.Floor);
    }

    /*
     @dev The `previewRedeem` function is used to preview the amount of assets
        that would be redeemed for `shares` amount of shares for a specified epoch.
     @param epochId The epoch for which we want to know the amount of assets
        that would be redeemed.
     @param shares The amount of shares for which we want to know the amount of
        assets that would be redeemed.
     @return The amount of assets that would be redeemed for `shares` amount of
    shares.
    */
    function previewRedeem(uint256 shares, uint256 epochId) public view returns (uint256) {
        return _convertWithdrawReceiptToAssets(epochId, shares, Math.Rounding.Floor);
    }

    function deposit(uint256 assets, address receiver)
        public
        whenNotPaused
        returns (uint256)
    {
        return deposit(_msgSender(), receiver, epochNonce - 1, assets);
    }

    // assets = Deposit request receipt balance
    // shares = shares to mint
    // TODO: check allowance before burning the receipt
    function deposit(address owner, address receiver, uint256 requestId, uint256 assets)
        public
        returns (uint256)
    {
        uint256 maxAssets = maxDeposit(owner); // what he can claim from the last epoch request 
        if (assets > maxAssets) { // he is trying to claim more than he can by saying he has more pending Receipt that he has in reality
            revert ERC4626ExceededMaxDeposit(owner, assets, maxAssets);
        }

        uint256 sharesAmount = previewDeposit(requestId, assets);
        depositRequestReceipt.burn(owner, requestId, assets);
        // _mint(receiver, sharesAmount); // actually the shares have already been minted into the nextEpoch function
        IERC20(address(this)).safeTransfer(receiver, sharesAmount); // transfer the vault shares to the receiver
        globalShares[requestId] += sharesAmount; // decrease the globalShares

        emit Deposit(owner, receiver, assets, sharesAmount);

        return sharesAmount;
    }

    // TODO: implement this correclty if possible (it's not possible to know the mintable shares)
    function mint(uint256, address) public pure returns (uint256) {
        return 0;
    }

    // TODO: implement this correclty if possible (it's not possible to know the withdrawable assets)
    // TODO: check allowance before burning the receipt
    function withdraw(uint256, address, address)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function redeem(uint256 shares, address receiver, address owner)
        external
        whenNotPaused
        returns (uint256)
    {
        return redeem(owner, receiver, epochNonce - 1, shares);
    }
    
    function redeem(address owner, address receiver, uint256 requestId, uint256 shares)
        public
        returns (uint256)
    {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);

        uint256 assetsAmount = previewRedeem(requestId, shares);
        withdrawRequestReceipt.burn(owner, requestId, shares);

        _asset.safeTransfer(receiver, assetsAmount);
        globalAssets[requestId] -= assetsAmount; // decrease the globalAssets

        emit Withdraw(_msgSender(), receiver, owner, assetsAmount, shares);

        return assetsAmount;
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        return assets.mulDiv(
            totalSupply() + 1, totalAssets + 1, rounding
        );
    }

    function _convertDepositReceiptToShares(uint256 epochId, uint256 assets, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        return assets.mulDiv(
            globalShares[epochId] + 1, depositRequestReceipt.totalSupply(epochId) + 1, rounding
        );
    }

    function _convertWithdrawReceiptToAssets(uint256 epochId, uint256 pendingReceipts, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        return pendingReceipts.mulDiv(
            globalAssets[epochId] + 1, withdrawRequestReceipt.totalSupply(epochId) + 1, rounding
        );
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        return shares.mulDiv(
            totalAssets + 1, totalSupply() + 1, rounding
        );
    }

    /*
     ####################################
      AMPHOR SYNTHETIC RELATED FUNCTIONS
     ####################################
    */

    function nextEpoch(uint256 returnedUnderlyingAmount) public onlyOwner returns (uint256) {
        // (end + start epochs)

        // TODO
        // 1. take fees from returnedUnderlyingAmount
        // 7. we update the totalAssets
        // 2. with the resting amount we know how much cost a share
        // 3. we can take the pending deposits underlying (same as this vault underlying) and mint shares
        // 4. we update the globalShares array for the appropriate epoch (epoch 0 request is a deposit into epoch 1...)
        // 5. we can take the pending withdraws shares and redeem underlying (which are shares of this vault) against this vault underlying
        // 6. we update the globalAssets array for the appropriate epoch (epoch 0 request is a withdraw at the end of the epoch 0...)

        ///////////////////////
        // Ending current epoch
        ///////////////////////
        uint256 fees;

        if (returnedUnderlyingAmount > totalAssets && feesInBps > 0) {
            uint256 profits;
            unchecked {
                profits = returnedUnderlyingAmount - totalAssets;
            }
            fees = (profits).mulDiv(feesInBps, 10000, Math.Rounding.Ceil);
        }

        totalAssets = returnedUnderlyingAmount - fees;

        // Can be done in one time at the end
        SafeERC20.safeTransferFrom(
            _asset, _msgSender(), address(this), returnedUnderlyingAmount - fees
        );

        emit EpochEnd(
            block.timestamp,
            totalAssets,
            returnedUnderlyingAmount,
            fees,
            totalSupply()
        );

        ///////////////////
        // Pending deposits
        ///////////////////
        uint256 pendingDeposit = depositRequestReceipt.nextEpoch(epochNonce); // get the underlying of the pending deposits
        // Updating the globalShares array
        globalShares.push(pendingDeposit.mulDiv(
            totalSupply() + 1, totalAssets + 1, Math.Rounding.Floor
        ));
        // Minting the shares
        _mint(address(this), globalShares[epochNonce]); // mint the shares into the vault
        // Update the totalAssets
        totalAssets += pendingDeposit;

        /////////////////
        // Pending redeem
        /////////////////
        uint256 pendingRedeem = withdrawRequestReceipt.nextEpoch(epochNonce); // get the shares of the pending withdraws
        // Updating the globalAssets array
        globalAssets.push(pendingRedeem.mulDiv(
            totalAssets + 1, totalSupply() + 1, Math.Rounding.Floor
        ));
        // Burn the vault shares
        _burn(address(this), pendingRedeem); // burn the shares from the vault
        // Update the totalAssets
        totalAssets -= globalAssets[epochNonce];

        //////////////////
        // Start new epoch
        //////////////////
        _asset.safeTransfer(owner(), totalAssets);

        emit EpochStart(block.timestamp, totalAssets, totalSupply());

        return ++epochNonce;
    }

    /**
     * @dev The `setFees` function is used to modify the protocol fees.
     * @notice The `setFees` function is used to modify the perf fees.
     * It can only be called by the owner of the contract (`onlyOwner` modifier).
     * It can't exceed 30% (3000 in BPS).
     * @param newFees The new perf fees to be applied.
     */
    function setFees(uint16 newFees) external onlyOwner {
        if (newFees > 3000) revert FeesTooHigh();
        feesInBps = newFees;
        emit FeesChanged(feesInBps, newFees);
    }

    // TODO: Finish to implement this correclty
    /**
     * @dev The `claimToken` function is used to claim other tokens that have
     * been sent to the vault.
     * @notice The `claimToken` function is used to claim other tokens that have
     * been sent to the vault.
     * It can only be called by the owner of the contract (`onlyOwner` modifier).
     * @param token The IERC20 token to be claimed.
     */
    function claimToken(IERC20 token) external onlyOwner {
        if (token == _asset) {/*TODO: get the discrepancy between returned assets and pending deposits*/}
        token.safeTransfer(_msgSender(), token.balanceOf(address(this)));
    }

    /*
     ####################################
      Pausability RELATED FUNCTIONS
     ####################################
    */
    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function _update(address from, address to, uint256 value) internal virtual override(ERC20, ERC20Pausable) whenNotPaused {
        super._update(from, to, value);
    }

    /*
     ###########################
      PERMIT2 RELATED FUNCTIONS
     ###########################
    */

    // Deposit some amount of an ERC20 token into this contract
    // using Permit2.
    function execPermit2(
        Permit2Params calldata permit2Params
    ) internal {
        // Transfer tokens from the caller to ourselves.
        permit2.permitTransferFrom(
            // The permit message.
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: permit2Params.token,
                    amount: permit2Params.amount
                }),
                nonce: permit2Params.nonce,
                deadline: permit2Params.deadline
            }),
            // The transfer recipient and amount.
            ISignatureTransfer.SignatureTransferDetails({
                to: address(this),
                requestedAmount: permit2Params.amount
            }),
            // The owner of the tokens, which must also be
            // the signer of the message, otherwise this call
            // will fail.
            _msgSender(),
            // The packed signature that was the result of signing
            // the EIP712 hash of `permit`.
            permit2Params.signature
        );
    }

    function requestDepositWithPermit2(
        uint256 assets,
        address receiver,
        address owner,
        Permit2Params calldata permit2Params
    ) external {
        if (_asset.allowance(owner, address(this)) < assets)
            execPermit2(permit2Params);
        return requestDeposit(assets, receiver, owner);
    }
}