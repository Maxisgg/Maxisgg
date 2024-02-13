// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.0 <0.9.0;

error InvalidParams();
error IllegalState();
error PermissionDenied();
error InvalidToken();
error InsufficientBalance();
error PaymentFailed();
error NoOfferFound();
error DuplicatedOperation();
error Unauthorized();
error InvalidNonce();
error InvalidSignature();

struct OfferData {
    address owner;
    uint32 tokenContract;
    uint32 amount; // unit: Szabo(1e12), should (x * 1e12) before use it, *** save gas ***
    uint8 count;
    uint8 remain;
    bool weth;
}

enum LoanStatus {
    ACTIVE, // repayment period is not yet due
    REPAID, // borrowers pay back on time
    LIQUIDATED // lender has liquidated the loan
}

struct LoanData {
    // slot 1
    address borrower;
    uint32 offerId;
    uint32 loanAmount; // unit: Szabo(1e12), should (x * 1e12) before use it, *** save gas ***
    uint32 repayAmount; // unit: Szabo(1e12), should (x * 1e12) before use it, *** save gas ***
    // slot 2
    uint32 endTime;
    uint32 tokenContract;
    uint8 durationDays;
    LoanStatus status;
    bytes20 tokenIds;
    uint8 count;
    bool weth;
}

struct BorrowData {
    uint32 offerId;
    uint32 loanAmount; // unit: Szabo(1e12), should (x * 1e12) before use it, *** save gas ***
    uint32 repayAmount; // unit: Szabo(1e12), should (x * 1e12) before use it, *** save gas ***
    uint8 durationDays;
    uint256 nonce;
    bytes signature;
}

struct Config {
    address signer;
    uint32 loanId;
    uint32 offerId;
    uint16 feeRate;
    uint16 nonceTimeout; // seconds timeout of nonce
    uint32 tokenId;
}