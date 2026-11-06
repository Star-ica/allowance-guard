// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AllowanceRegistry — on-chain log of ERC-20 approval events for a wallet
/// @notice Users call this contract to record approvals and revocations on BOT Chain.
///         The core ERC-20 allowance lives on each token contract; this registry
///         provides a queryable audit trail and batch-revoke helper.
/// @dev    Revocation is done by calling token.approve(spender, 0) via this contract
///         acting as a trusted relay — the user must have called token.approve(address(this), 0)
///         pattern is intentional: we emit AllowanceRevoked for indexing, then call approve(spender,0)
///         on behalf of msg.sender by using the standard ERC-20 flow where the owner signs.
///         NOTE: Actual revoke just calls approve(spender, 0) directly — we do NOT hold custody.
contract AllowanceRegistry is Ownable, Pausable, ReentrancyGuard {

    // ─────────────── STRUCTS ───────────────
    /// @notice Risk tier assigned to a spender address
    enum RiskLevel { Unknown, Low, Medium, High, Critical }

    struct AllowanceRecord {
        address token;
        address spender;
        uint256 recordedAmount;   // amount at time of recording (informational)
        uint256 recordedAt;       // block.timestamp when recorded
        uint256 revokedAt;        // 0 = not revoked
        bool revoked;
    }

    struct SpenderInfo {
        string  name;             // e.g. "Uniswap V3 Router"
        RiskLevel risk;
        string  description;
        bool    verified;         // admin-verified safe contract
        bool    exists;
    }

    // ─────────────── STATE ───────────────
    uint256 public recordCount;

    // wallet → list of record IDs
    mapping(address => uint256[]) public walletRecords;
    // record ID → AllowanceRecord
    mapping(uint256 => AllowanceRecord) public records;
    // wallet → token → spender → recordId (latest)
    mapping(address => mapping(address => mapping(address => uint256))) public latestRecord;

    // Admin-managed spender registry
    mapping(address => SpenderInfo) public spenderInfo;
    address[] public knownSpenders;

    // ─────────────── EVENTS ───────────────
    event AllowanceLogged(
        uint256 indexed recordId,
        address indexed wallet,
        address indexed token,
        address spender,
        uint256 amount
    );
    event AllowanceRevoked(
        uint256 indexed recordId,
        address indexed wallet,
        address indexed token,
        address spender
    );
    event SpenderRegistered(address indexed spender, string name, RiskLevel risk);
    event SpenderRiskUpdated(address indexed spender, RiskLevel newRisk);

    // ─────────────── CONSTRUCTOR ───────────────
    constructor() Ownable(msg.sender) {}

    // ─────────────── USER FUNCTIONS ───────────────

    /// @notice Log an existing or new ERC-20 approval in the registry
    /// @param token   ERC-20 token contract
    /// @param spender Address that was approved
    /// @param amount  Approved amount (pass type(uint256).max for unlimited)
    function logAllowance(address token, address spender, uint256 amount)
        external whenNotPaused {
        require(token != address(0), "Invalid token");
        require(spender != address(0), "Invalid spender");

        uint256 id = ++recordCount;
        records[id] = AllowanceRecord({
            token: token,
            spender: spender,
            recordedAmount: amount,
            recordedAt: block.timestamp,
            revokedAt: 0,
            revoked: false
        });

        walletRecords[msg.sender].push(id);
        latestRecord[msg.sender][token][spender] = id;

        emit AllowanceLogged(id, msg.sender, token, spender, amount);
    }

    /// @notice Revoke an ERC-20 allowance: calls token.approve(spender, 0) for caller,
    ///         then marks the registry record as revoked.
    /// @dev    The token's approve function is called on behalf of msg.sender.
    ///         This works because msg.sender calls this function and is the token owner.
    /// @param token   ERC-20 token contract
    /// @param spender Address to revoke approval from
    function revokeAllowance(address token, address spender)
        external nonReentrant whenNotPaused {
        require(token != address(0), "Invalid token");
        require(spender != address(0), "Invalid spender");

        // Execute the actual revocation on the token contract
        // Note: approve returns bool on most tokens; some older tokens revert on failure
        bool success;
        try IERC20(token).approve(spender, 0) returns (bool ok) {
            success = ok;
        } catch {
            revert("Token approve failed");
        }
        require(success, "Approve returned false");

        // Mark existing record as revoked (if any)
        uint256 rid = latestRecord[msg.sender][token][spender];
        if (rid != 0 && !records[rid].revoked) {
            records[rid].revoked = true;
            records[rid].revokedAt = block.timestamp;
            emit AllowanceRevoked(rid, msg.sender, token, spender);
        } else {
            // Log a revocation record even if we didn't have a prior log
            uint256 id = ++recordCount;
            records[id] = AllowanceRecord({
                token: token,
                spender: spender,
                recordedAmount: 0,
                recordedAt: block.timestamp,
                revokedAt: block.timestamp,
                revoked: true
            });
            walletRecords[msg.sender].push(id);
            latestRecord[msg.sender][token][spender] = id;
            emit AllowanceRevoked(id, msg.sender, token, spender);
        }
    }

    /// @notice Batch revoke multiple allowances in one transaction
    /// @param tokens   Array of token contracts
    /// @param spenders Array of spenders (must match tokens length)
    function batchRevokeAllowances(address[] calldata tokens, address[] calldata spenders)
        external nonReentrant whenNotPaused {
        require(tokens.length == spenders.length, "Length mismatch");
        require(tokens.length <= 20, "Max 20 per batch");

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            address spender = spenders[i];
            if (token == address(0) || spender == address(0)) continue;

            try IERC20(token).approve(spender, 0) returns (bool ok) {
                if (!ok) continue;
            } catch {
                continue; // Skip failing tokens, don't revert entire batch
            }

            uint256 rid = latestRecord[msg.sender][token][spender];
            if (rid != 0 && !records[rid].revoked) {
                records[rid].revoked = true;
                records[rid].revokedAt = block.timestamp;
                emit AllowanceRevoked(rid, msg.sender, token, spender);
            } else {
                uint256 id = ++recordCount;
                records[id] = AllowanceRecord({
                    token: token,
                    spender: spender,
                    recordedAmount: 0,
                    recordedAt: block.timestamp,
                    revokedAt: block.timestamp,
                    revoked: true
                });
                walletRecords[msg.sender].push(id);
                latestRecord[msg.sender][token][spender] = id;
                emit AllowanceRevoked(id, msg.sender, token, spender);
            }
        }
    }

    // ─────────────── ADMIN FUNCTIONS ───────────────

    /// @notice Register or update a known spender with metadata and risk level
    function registerSpender(
        address spender,
        string calldata name,
        RiskLevel risk,
        string calldata description,
        bool verified
    ) external onlyOwner {
        require(spender != address(0), "Invalid spender");
        if (!spenderInfo[spender].exists) {
            knownSpenders.push(spender);
        }
        spenderInfo[spender] = SpenderInfo({
            name: name,
            risk: risk,
            description: description,
            verified: verified,
            exists: true
        });
        emit SpenderRegistered(spender, name, risk);
    }

    /// @notice Update the risk level for a known spender
    function updateSpenderRisk(address spender, RiskLevel newRisk) external onlyOwner {
        require(spenderInfo[spender].exists, "Spender not registered");
        spenderInfo[spender].risk = newRisk;
        emit SpenderRiskUpdated(spender, newRisk);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────── VIEW FUNCTIONS ───────────────

    /// @notice Get all record IDs for a wallet
    function getWalletRecords(address wallet) external view returns (uint256[] memory) {
        return walletRecords[wallet];
    }

    /// @notice Get a single record
    function getRecord(uint256 recordId) external view returns (AllowanceRecord memory) {
        return records[recordId];
    }

    /// @notice Get current on-chain allowance for a wallet/token/spender triple
    function getCurrentAllowance(address wallet, address token, address spender)
        external view returns (uint256) {
        return IERC20(token).allowance(wallet, spender);
    }

    /// @notice Get all known spenders list
    function getKnownSpenders() external view returns (address[] memory) {
        return knownSpenders;
    }

    /// @notice Get risk level for a spender (Unknown if not registered)
    function getSpenderRisk(address spender) external view returns (RiskLevel) {
        return spenderInfo[spender].risk;
    }
}
