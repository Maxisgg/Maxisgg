// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.0 <0.9.0;

import {BorrowData} from "./Types.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

library Utils {

    function getChainID() private view returns (uint256 id) {
        assembly {
            id := chainid()
        }
    }

    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        // 32 is the length in bytes of hash,
        // enforced by the type signature above
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    // pack uint16[] to bytes20, save gas
    function packTokenIds(uint16[] calldata _tokenIds, uint _len) internal pure returns (bytes20) {
        bytes20 packed = bytes20(0);
        // pack token ids
        for (uint i; i < _len; i++) {
            packed |= (bytes20(bytes2(_tokenIds[i])) >> (i * 16));
        }
        return packed;
    }

    // unpack bytes20 to uint16[], save gas
    function unpackTokenIds(bytes20 _packed, uint count) internal pure returns (uint16[] memory) {
        bytes2 mask = 0xFFFF;
        // unpack token ids
        uint16[] memory tokenIds = new uint16[](count);
        for (uint i; i < count; i++) {
            bytes20 v = (_packed << (i * 16)) & mask;
            tokenIds[i] = uint16(bytes2(v));
        }
        return tokenIds;
    }

    // verify borrow signature
    function verifyBorrowSignature(address _signer, BorrowData calldata _borrow, address _tokenContract, bytes20 tokenIds) internal view returns (bool) {
        if (_signer == address(0)) return false;

        bytes32 message = keccak256(getEncodedBorrow(_borrow, _tokenContract, tokenIds));
        return SignatureChecker.isValidSignatureNow(_signer, toEthSignedMessageHash(message), _borrow.signature);
    }

    function getEncodedBorrow(BorrowData calldata _borrow, address _tokenContract, bytes20 tokenIds) private view returns (bytes memory) {
        return abi.encodePacked(
            _borrow.offerId,
            _tokenContract,
            _borrow.loanAmount,
            _borrow.repayAmount,
            _borrow.durationDays,
            _borrow.nonce,
            tokenIds,
            address(this),
            getChainID()
        );
    }

    function packArray(uint16[] calldata array) external pure returns (bytes memory) {
        bytes memory output;
        for (uint i = array.length - 1; i >= 0; i--) {
            output = abi.encodePacked(output, array[i]);
        }
        return output;
    }
}