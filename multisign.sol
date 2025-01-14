// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.0/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MultisignWallet is Ownable {
    using Address for address;

    struct WithdrawalRequest {
        uint256 txId;
        address tokenAddress;
        address requester;
        address toAddress;
        uint256 amount;
        uint256 expiryTime;
        bool isPending;
        uint256 approvalCount;
        mapping(address => bool) approvals;
    }
    mapping(uint256 => WithdrawalRequest) public requests;
    mapping(address => bool) public isOwner;

    address[] public owners;
    uint256 public approveRequired;
    uint256 public requestCount;
    uint256 public lastEmergencyWithdrawTime;


    event WithdrawalRequestCreated(uint256 txId, address token, address requester, address toAddress, uint256 amount, uint256 expiryTime);
    event WithdrawalRequestExpired(uint256 txId);
    event WithdrawalRequestExecuted(uint256 txId, address token, address toAddress, uint256 amount);
    event EmergencyETHWithdrawal(address indexed to, uint256 amount, uint256 timestamp);
    event EmergencyTokenWithdrawal(address indexed to, address token, uint256 amount, uint256 timestamp);

    constructor(address[] memory _owners, uint _approveRequired) Ownable(msg.sender) {
        require(_owners.length > 1 && _owners.length >= _approveRequired, "Approvers should be less than Owners");

        for (uint i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "invalid owner");
            require(!isOwner[owner], "owner not unique");

            isOwner[owner] = true;
            owners.push(owner);
        }
        approveRequired = _approveRequired;
    }

    modifier initializeOwner() {
        require(isOwner[msg.sender], "not owner");
        _;
    }

    modifier notContract() {
        require(!msg.sender.isContract(), "Contract is not allowed to swap");
        require(msg.sender == tx.origin, "No proxy contract is allowed");
        _;
    }

    receive() external payable {}

    function isETH(address _tokenAddress) private pure returns (bool) {
        return _tokenAddress == address(0); 
    }

    function createWithdrawalRequest(address _tokenAddress, address toAddress, uint256 amount) external notContract returns (uint256 txId) {
        // Check if there is any pending request
        if (requestCount > 0) {
            WithdrawalRequest storage existingRequest = requests[requestCount];
            if (existingRequest.isPending && block.timestamp <= existingRequest.expiryTime) {
                revert("A request is already pending and valid.");
            }
            if (existingRequest.isPending && block.timestamp > existingRequest.expiryTime) {
                existingRequest.isPending = false;
                emit WithdrawalRequestExpired(existingRequest.txId);
            }
        }

        // Check if the token is ETH (address(0) is ETH) 
        if (isETH(_tokenAddress)) {
            require(address(this).balance >= amount, "Insufficient ETH balance");
        } else {
            require(IERC20(_tokenAddress).balanceOf(address(this)) >= amount, "Insufficient ERC20 balance");
        }

        // Increment request count
        requestCount++;
        txId = requestCount;

        WithdrawalRequest storage newRequest = requests[txId];
        newRequest.tokenAddress = _tokenAddress;
        newRequest.requester = msg.sender;
        newRequest.toAddress = toAddress;
        newRequest.amount = amount;
        newRequest.expiryTime = block.timestamp + 1 hours;
        newRequest.isPending = true;
        newRequest.txId = txId;
        newRequest.approvalCount = 0;

        emit WithdrawalRequestCreated(txId, _tokenAddress, msg.sender, toAddress, amount, block.timestamp + 1 hours);

        return txId;
    }

    // This function allows an owner to approve a withdrawal request
    function approveWithdrawal(uint256 txId) external initializeOwner {
        WithdrawalRequest storage request = requests[txId];
        require(request.isPending, "Request is not pending");
        require(!request.approvals[msg.sender], "You have already approved this request");

        request.approvals[msg.sender] = true;
        request.approvalCount++;

        // If enough approvals are reached, execute the withdrawal
        if (request.approvalCount >= approveRequired) {
            executeWithdrawal(txId);
        }
    }

    function executeWithdrawal(uint256 txId) internal {
        WithdrawalRequest storage request = requests[txId];
        require(request.approvalCount >= approveRequired, "Not enough approvals");

        request.isPending = false;

        if (isETH(request.tokenAddress)) {
            (bool success, ) = request.toAddress.call{value: request.amount}("");
            require(success, "ETH transfer failed");
        } else {
            require(IERC20(request.tokenAddress).transfer(request.toAddress, request.amount), "ERC20 transfer failed");
        }

        emit WithdrawalRequestExecuted(txId, request.tokenAddress, request.toAddress, request.amount);
    }

    function emergencyWithdraw(address token) external onlyOwner {
        if (token == address(0)) {
            uint256 amount = 0.1 ether;

            require(address(this).balance >= amount, "Insufficient ETH balance");
            require(block.timestamp >= lastEmergencyWithdrawTime + 24 hours, "Emergency withdrawal can only be called once every 24 hours");

            lastEmergencyWithdrawTime = block.timestamp;
            (bool success, ) = owner().call{value: amount}("");
            require(success, "ETH transfer failed");

            emit EmergencyETHWithdrawal(owner(), amount, block.timestamp);
        } else {
            uint256 amount = 10*1e6;
            require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient token balance");
            require(block.timestamp >= lastEmergencyWithdrawTime + 24 hours, "Emergency withdrawal can only be called once every 24 hours");

            lastEmergencyWithdrawTime = block.timestamp;

            bool success = IERC20(token).transfer(owner(), amount);
            require(success, "ERC20 transfer failed");

            emit EmergencyTokenWithdrawal(owner(), token, amount, block.timestamp);
        }
    }

}
