// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.0 <0.9.0;
pragma experimental ABIEncoderV2;

import "./Types.sol";
import "./Utils.sol";
import "./interfaces/IBlast.sol";
import "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Lending
 * @dev Ultra simple, fast, and safe.
        Borrow against your NFTs instantly.
        Earn a high yield on your sitting crypto.
 */
contract PanzLending is AccessControl, ConfirmedOwner, ReentrancyGuard {

    uint256 constant private PRICE_UNIT = 1e12;
    // the divisor of fee rate
    uint256 constant private RATE_DIVISOR = 10000;
    // the max duration days
    uint8 constant private MAX_LOAN_DAYS = 28;
    // the maximum number of offers in one order, must < 10, because packed tokenIds is bytes20
    uint8 constant private MAX_OFFER_COUNT = 10;

    // balance of share fee
    uint256 public feeBalance;
    uint256 public feeBalanceWeth;
    // global config
    Config public config;
    // contract => lender => OfferData
    mapping(uint32 => OfferData) public offers;
    // contract => borrower => LoanData
    mapping(uint32 => LoanData) public loans;
    // verified token contract => token id
    mapping(address=>uint32) public tokens;
    // the recent time mills of signature for each customer
    mapping(address=>uint256) public nonces;
    // WETH token
    IERC20 private wethToken;

    bytes32 private constant MANAGER_ROLE = keccak256("MANAGER");

    address public blastYield = 0x4300000000000000000000000000000000000002;

    // offer event
    event onOfferAdd(uint32 indexed id, address indexed ower);
    event onOfferEdit(uint32 indexed id, address indexed ower);
    event onOfferRevoke(uint32 indexed id, address indexed ower);
    // loan event
    event onLoanStart(uint32 indexed id);
    event onLoanRepay(uint32 indexed id);
    event onLoanLiquidate(uint32 indexed id);
    // other event
    event onTokenVerified(uint32 indexed id, address indexed tokenContract);
    event onSetConfig(address indexed signer, uint16 feeRate, uint16 timeOut);

    // polygon weth: 0x7ceb23fd6bc0add59e62ac25578270cff1b9f619
    constructor(address _weth) ConfirmedOwner(msg.sender) {
        config.feeRate = 2000;
        config.nonceTimeout = 3600;
        wethToken = IERC20(_weth);
        _grantRole(MANAGER_ROLE, msg.sender);

        IBlast(blastYield).configureClaimableYield();
        IBlast(blastYield).configureClaimableGas();
    }

    /**
     * @dev set configurations
     */
    function setConfig(address _signer, uint16 _feeRate, uint16 _timeout) external onlyOwner {
        config.nonceTimeout = _timeout;
        config.feeRate = _feeRate;
        config.signer = _signer;
        emit onSetConfig(_signer, _feeRate, _timeout);
    }

    /**
     * @dev set wethToken
     */
    function setWethToken(address _weth) external onlyOwner {
        wethToken = IERC20(_weth);
    }

    /**
     * @dev claim platform fee
     */
    function withdrawFee() external onlyOwner nonReentrant {
        if (feeBalance == 0 && feeBalanceWeth == 0) revert InsufficientBalance();

        if (feeBalance > 0) {
            (bool success,) = payable(msg.sender).call{value: feeBalance}("");
            if(!success) revert PaymentFailed();
        }

        if (feeBalanceWeth > 0) {
            bool succ = wethToken.transfer(msg.sender, feeBalanceWeth);
            if(!succ) revert PaymentFailed();
        }

        feeBalance = 0;
        feeBalanceWeth = 0;
    }

    /**
     * @dev verify token
     */
    function verify(address _tokenContract) external onlyRole(MANAGER_ROLE) {
        if(tokens[_tokenContract] != 0) revert DuplicatedOperation();
        tokens[_tokenContract] = ++config.tokenId;

        emit onTokenVerified(config.tokenId, _tokenContract);
    }

    /**
     * @dev deposit ETH to pool
     */
    function addOffer(uint32 _offerId, address _tokenContract, uint32 _amount, uint8 _count, bool _weth) external payable returns (uint32) {
        if(_amount == 0 || _count == 0 || _count > MAX_OFFER_COUNT) revert InvalidParams();
        uint32 collectionId = tokens[_tokenContract];
        if(collectionId == 0) revert InvalidToken();
        
        // generate/reuse offer if
        uint32 offerId;
        if (_offerId != 0) {
            if(offers[_offerId].count != 0) revert IllegalState();
            if(offers[_offerId].owner != msg.sender) revert PermissionDenied();
            offerId = _offerId;
        } else {
            offerId = ++config.offerId;
        }
        // calculate total amount of offers
        uint256 totalAmount = uint256(_amount) * PRICE_UNIT * uint256(_count);
        if (_weth)  { // deposit weth to contract
            bool succ = wethToken.transferFrom(msg.sender, address(this), totalAmount);
            if (!succ) revert InsufficientBalance();
        } else {
            if(msg.value != totalAmount) revert InsufficientBalance();
        }
        offers[offerId] = OfferData(msg.sender, collectionId, _amount, _count, _count, _weth);

        emit onOfferAdd(offerId, msg.sender);

        return offerId;
    }

    /**
     * @dev edit my offer
     */
    function editOffer(uint32 _offerId, uint32 _amount, uint8 _count) external payable nonReentrant {
        if(_amount == 0 || _count == 0 || _count > MAX_OFFER_COUNT) revert InvalidParams();
        // check offer status
        OfferData storage offerData = offers[_offerId];
        if(offerData.count == 0) revert NoOfferFound();
        if(offerData.owner != msg.sender) revert PermissionDenied();
        if(offerData.count == _count && offerData.amount == _amount) revert InvalidParams();

        uint8 remainNum = offerData.remain;
        if (_count > offerData.count) {
            // add liquidity to pool
            offerData.remain += _count - offerData.count;
        } else if (_count < offerData.count) {
            // you cannot cut the liquidity to lower than borrowed number
            if(offerData.count - remainNum > _count) revert InvalidParams();
            offerData.remain -= offerData.count - _count;
        }

        // calculate amount
        uint256 newAmount = uint256(_amount) * PRICE_UNIT * (remainNum + _count - offerData.count);
        uint256 remainAmount = uint256(offerData.amount) * PRICE_UNIT * remainNum;
        if (newAmount > remainAmount) { // deposit
            uint256 totalAmount = newAmount - remainAmount;
            if (offerData.weth) {
                bool succ = wethToken.transferFrom(msg.sender, address(this), totalAmount);
                if (!succ) revert InsufficientBalance();
            } else {
                if(msg.value != totalAmount) revert InsufficientBalance();
            }
        } else if (newAmount < remainAmount) { // withdraw
            uint256 totalAmount = remainAmount - newAmount;
            if (offerData.weth) {
                bool succ = wethToken.transfer(msg.sender, totalAmount);
                if (!succ) revert InsufficientBalance();
            } else {
                (bool success,) = payable(msg.sender).call{value: totalAmount}("");
                if(!success) revert PaymentFailed();
            }
        }

        offerData.amount = _amount;
        offerData.count = _count;

        emit onOfferEdit(_offerId, msg.sender);
    }

    /**
     * @dev revoke my offer
     */
    function revokeOffer(uint32 _offerId) external nonReentrant {
        OfferData memory offerData = offers[_offerId];
        if(offerData.count == 0 || offerData.remain == 0) revert NoOfferFound();
        if(offerData.owner != msg.sender) revert PermissionDenied();

        uint256 totalAmount = uint256(offerData.amount) * PRICE_UNIT * offerData.remain;
        if (offerData.weth) {
            bool succ = wethToken.transfer(msg.sender, totalAmount);
            if (!succ) revert InsufficientBalance();
        } else {
            (bool success,) = payable(msg.sender).call{value: totalAmount}("");
            if(!success) revert InsufficientBalance();
        }

        offers[_offerId].count -= offerData.remain;
        offers[_offerId].remain = 0;

        emit onOfferRevoke(_offerId, msg.sender);
    }

    /**
     * @dev borrow one nft
     */
    function borrow(BorrowData calldata _borrow, address _tokenContract, uint16[] calldata _tokenIds) external nonReentrant returns (uint32) {
        _validateBorrowData(_borrow);

        // check number of tokens
        uint tokenLen = _tokenIds.length;
        if (tokenLen == 0 || tokens[_tokenContract] == 0) revert InvalidParams();

        // pack token ids to save gas
        bytes20 packed = Utils.packTokenIds(_tokenIds, tokenLen);
        // verify signature
        if(!Utils.verifyBorrowSignature(config.signer, _borrow, _tokenContract, packed)) revert InvalidSignature();

        // check offer status
        OfferData memory offerData = offers[_borrow.offerId];
        if(offerData.remain < tokenLen) revert IllegalState();
        if(offerData.tokenContract != tokens[_tokenContract]) revert InvalidParams();

        // check loan amout
        uint256 totalAmount = uint256(offerData.amount) * tokenLen;
        if (totalAmount != _borrow.loanAmount) revert InvalidParams();

        // record the loan
        uint32 endTime = uint32(block.timestamp) + uint32(_borrow.durationDays) * 86400;
        loans[++config.loanId] = LoanData(msg.sender, _borrow.offerId, _borrow.loanAmount, 
                                          _borrow.repayAmount, endTime, offerData.tokenContract,
                                          _borrow.durationDays, LoanStatus.ACTIVE, packed, uint8(tokenLen), offerData.weth);
        offers[_borrow.offerId].remain -= uint8(tokenLen);
        nonces[msg.sender] = _borrow.nonce;

        // transfer NFT to contract, need setApprovalForAll first
        IERC721 erc721Token = IERC721(_tokenContract);
        for (uint i; i < tokenLen; i++) {
            erc721Token.transferFrom(msg.sender, address(this), uint256(_tokenIds[i]));
        }

        // send eth to borrower, unit is GWEI, must mul(PRICE_UNIT) before send
        if (offerData.weth) {
            bool succ = wethToken.transfer(msg.sender, totalAmount * PRICE_UNIT);
            if (!succ) revert InsufficientBalance();
        } else {
            (bool success,) = payable(msg.sender).call{value: totalAmount * PRICE_UNIT}("");
            if(!success) revert PaymentFailed();
        }

        emit onLoanStart(config.loanId);
        return config.loanId;
    }

    /**
     * @dev extend a loan
     */
    function extend(uint32 _loanId, BorrowData calldata _borrow, address _tokenContract) external payable nonReentrant returns (uint32) {
        _validateBorrowData(_borrow);
        // load the old load data
        LoanData memory loanData = loans[_loanId];
        _validateLoanData(loanData, _tokenContract);
        // load the new offer data
        OfferData memory offerData = offers[_borrow.offerId];
        OfferData memory repayOffer = offers[loanData.offerId];
        if(offerData.remain < loanData.count) revert IllegalState();
        if(offerData.weth != repayOffer.weth) revert InvalidParams();
        if(offerData.tokenContract != tokens[_tokenContract]) revert InvalidParams();

        // check the new loan amout
        uint256 newAmount = uint256(offerData.amount) * loanData.count;
        if (newAmount != _borrow.loanAmount) revert InvalidParams();

        // verify signature
        if(!Utils.verifyBorrowSignature(config.signer, _borrow, _tokenContract, loanData.tokenIds)) revert InvalidSignature();

        // calculate repayment and repay the old loan
        uint256 repayWei = uint256(loanData.repayAmount) * PRICE_UNIT;
        uint256 loanWei = uint256(loanData.loanAmount) * PRICE_UNIT;
        uint256 newLoanWei = newAmount * PRICE_UNIT;

        if (repayWei > newLoanWei) { // should deposit
            if (offerData.weth) {
                bool succ = wethToken.transferFrom(msg.sender, address(this), repayWei - newLoanWei);
                if (!succ) revert InsufficientBalance();
            } else {
                if (msg.value != (repayWei - newLoanWei)) revert InsufficientBalance();
            }
        } else if (repayWei < newLoanWei) { // receive more eth/matic
            if (msg.value != 0) revert InvalidParams();

            if (offerData.weth) {
                bool succ = wethToken.transfer(msg.sender, newLoanWei - repayWei);
                if (!succ) revert InsufficientBalance();
            } else {
                (bool sent,) = payable(loanData.borrower).call{value: newLoanWei - repayWei}("");
                if(!sent) revert PaymentFailed();
            }
        }
        
        // calculate share fee
        uint256 fee = (repayWei - loanWei) * config.feeRate / RATE_DIVISOR;
        // send principal & interest to old lender
        {
            if (repayOffer.weth) {
                bool succ = wethToken.transfer(repayOffer.owner, repayWei - fee);
                if (!succ) revert PaymentFailed();
            } else {
                (bool sent,) = payable(repayOffer.owner).call{value: repayWei - fee}("");
                if(!sent) revert PaymentFailed();
            }
        }
        // increase share fee
        if (fee != 0) { 
            if (offerData.weth)
                feeBalanceWeth += fee;
            else
                feeBalance += fee;
        }

        // update the old load and offer state
        loans[_loanId].status = LoanStatus.REPAID;
        offers[loanData.offerId].count -= loanData.count;

        // record the new loan
        uint32 endTime = uint32(block.timestamp) + uint32(_borrow.durationDays) * 86400;
        loans[++config.loanId] = LoanData(msg.sender, _borrow.offerId, _borrow.loanAmount, 
                                          _borrow.repayAmount, endTime, offerData.tokenContract,
                                          _borrow.durationDays, LoanStatus.ACTIVE, loanData.tokenIds, 
                                          loanData.count, offerData.weth);
        offers[_borrow.offerId].remain -= loanData.count;
        nonces[msg.sender] = _borrow.nonce;

        emit onLoanRepay(_loanId);
        emit onLoanStart(config.loanId);
        return config.loanId;
    }

    /**
     * @dev repay a loan
     */
    function repay(uint32 _loanId, address _tokenContract) external payable nonReentrant {
        LoanData memory loanData = loans[_loanId];
        _validateLoanData(loanData, _tokenContract);

        OfferData memory offerData = offers[loanData.offerId];

        // calculate repayment
        uint256 repayWei = uint256(loanData.repayAmount) * PRICE_UNIT;
        uint256 loanWei = uint256(loanData.loanAmount) * PRICE_UNIT;
        // calculate share fee
        uint256 fee = (repayWei - loanWei) * config.feeRate / RATE_DIVISOR;
        // send principal & interest to lender
        {
            if (offerData.weth) {
                // deposit repay amount
                bool succAll = wethToken.transferFrom(msg.sender, address(this), repayWei);
                if (!succAll) revert PaymentFailed();
                // transfer to lender
                bool succ = wethToken.transfer(offerData.owner, repayWei - fee);
                if (!succ) revert PaymentFailed();
            } else {
                if(msg.value != repayWei) revert InsufficientBalance();

                (bool sent,) = payable(offerData.owner).call{value: repayWei - fee}("");
                if(!sent) revert PaymentFailed();
            }
        }
        // increase share fee
        if (fee != 0) { 
            if (offerData.weth)
                feeBalanceWeth += fee;
            else
                feeBalance += fee;
        }
        
        // unpack token ids
        uint tokenLen = uint(loanData.count);
        uint16[] memory unpacked = Utils.unpackTokenIds(loanData.tokenIds, tokenLen);
        // transfer NFT to borrower
        IERC721 erc721Token = IERC721(_tokenContract);
        for (uint i; i < tokenLen; i++) {
            erc721Token.transferFrom(address(this), msg.sender, uint256(unpacked[i]));
        }
        // update state
        loans[_loanId].status = LoanStatus.REPAID;
        offers[loanData.offerId].count -= uint8(tokenLen);

        emit onLoanRepay(_loanId);
    }

    /**
     * @dev liquidation of due loans
     */
    function liquidate(uint32 _loanId, address _tokenContract) external nonReentrant {
        LoanData memory loanData = loans[_loanId];
        if(loanData.status != LoanStatus.ACTIVE || block.timestamp <= loanData.endTime) revert IllegalState();
        // wrong token contract
        if(loanData.tokenContract != tokens[_tokenContract]) revert InvalidParams();
        // caller is not the lender
        if(offers[loanData.offerId].owner != msg.sender) revert PermissionDenied();

        // unpack token ids
        uint tokenLen = uint(loanData.count);
        uint16[] memory unpacked = Utils.unpackTokenIds(loanData.tokenIds, tokenLen);
        // transfer NFT to lender
        IERC721 erc721Token = IERC721(_tokenContract);
        for (uint i; i < tokenLen; i++) {
            erc721Token.transferFrom(address(this), msg.sender, uint256(unpacked[i]));
        }
        offers[loanData.offerId].count -= uint8(tokenLen);
        loans[_loanId].status = LoanStatus.LIQUIDATED;

        emit onLoanLiquidate(_loanId);
    }

    function grantRole(bytes32 role, address account) public virtual override onlyOwner {
        _grantRole(role, account);
    }

    /**
     * @dev check borrow data
     */
    function _validateBorrowData(BorrowData calldata _borrow) internal view {
        if(_borrow.durationDays > MAX_LOAN_DAYS) revert InvalidParams();
        if(_borrow.repayAmount <= _borrow.loanAmount) revert InvalidParams();
        // check nonce, block replay attacks
        if (block.timestamp > _borrow.nonce) {
            if (block.timestamp - _borrow.nonce > config.nonceTimeout) revert InvalidNonce();
        } else {
            if (_borrow.nonce - block.timestamp > config.nonceTimeout) revert InvalidNonce();
        }
        if(_borrow.nonce <= nonces[msg.sender]) revert InvalidNonce();
    }

    /**
     * @dev check loan data
     */
    function _validateLoanData(LoanData memory _loan, address _tokenContract) internal view {
        if(_loan.offerId == 0) revert InvalidParams();
        // wrong loan status
        if(_loan.status != LoanStatus.ACTIVE) revert IllegalState();
        // caller is not the borrower
        if(_loan.borrower != msg.sender) revert PermissionDenied();
        // wrong token conntract
        if (_loan.tokenContract != tokens[_tokenContract]) revert InvalidParams();
    }

    // IBlast function

    function claimYield(address recipient) external onlyOwner {
        IBlast(blastYield).claimAllYield(address(this), recipient);
    }

    function claimAllGas(address recipient) external onlyOwner {
        IBlast(blastYield).claimAllGas(address(this), recipient);
    }

    function readGasParams() external view returns (uint256 etherSeconds, uint256 etherBalance, uint256 lastUpdated, GasMode) {
        return IBlast(blastYield).readGasParams(address(this));
    }

    function readClaimableYield() external view returns (uint256) {
        return IBlast(blastYield).readClaimableYield(address(this));
    }

    function readYieldConfiguration() external view returns (uint8) {
        return IBlast(blastYield).readYieldConfiguration(address(this));
    }
}