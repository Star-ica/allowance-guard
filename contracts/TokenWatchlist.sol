// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title TokenWatchlist — user-managed list of ERC-20 tokens to monitor for approvals
/// @notice Users add tokens they care about; the frontend queries these to check allowances.
contract TokenWatchlist is Ownable {

    struct TokenInfo {
        address tokenAddress;
        string  name;
        string  symbol;
        uint8   decimals;
        bool    adminVerified; // marked safe by admin
        bool    exists;
    }

    // Global admin-verified token list
    mapping(address => TokenInfo) public tokenRegistry;
    address[] public verifiedTokens;

    // Per-user watchlist
    mapping(address => address[]) public userWatchlist;
    mapping(address => mapping(address => bool)) public inWatchlist;

    event TokenVerified(address indexed token, string symbol);
    event TokenAddedToWatchlist(address indexed user, address indexed token);
    event TokenRemovedFromWatchlist(address indexed user, address indexed token);

    constructor() Ownable(msg.sender) {}

    // ─────────────── ADMIN ───────────────

    /// @notice Admin registers a verified token (name/symbol/decimals auto-read)
    function verifyToken(address token) external onlyOwner {
        require(token != address(0), "Invalid");
        require(!tokenRegistry[token].adminVerified, "Already verified");

        string memory name_ = "Unknown";
        string memory symbol_ = "???";
        uint8 decimals_ = 18;

        try IERC20Metadata(token).name() returns (string memory n) { name_ = n; } catch {}
        try IERC20Metadata(token).symbol() returns (string memory s) { symbol_ = s; } catch {}
        try IERC20Metadata(token).decimals() returns (uint8 d) { decimals_ = d; } catch {}

        tokenRegistry[token] = TokenInfo({
            tokenAddress: token,
            name: name_,
            symbol: symbol_,
            decimals: decimals_,
            adminVerified: true,
            exists: true
        });
        verifiedTokens.push(token);
        emit TokenVerified(token, symbol_);
    }

    // ─────────────── USER ───────────────

    /// @notice Add a token to your personal watchlist
    function addToWatchlist(address token) external {
        require(token != address(0), "Invalid");
        require(!inWatchlist[msg.sender][token], "Already watching");
        userWatchlist[msg.sender].push(token);
        inWatchlist[msg.sender][token] = true;

        // Auto-register token info if not already there
        if (!tokenRegistry[token].exists) {
            string memory name_ = "Unknown";
            string memory symbol_ = "???";
            uint8 decimals_ = 18;
            try IERC20Metadata(token).name() returns (string memory n) { name_ = n; } catch {}
            try IERC20Metadata(token).symbol() returns (string memory s) { symbol_ = s; } catch {}
            try IERC20Metadata(token).decimals() returns (uint8 d) { decimals_ = d; } catch {}
            tokenRegistry[token] = TokenInfo({
                tokenAddress: token, name: name_, symbol: symbol_,
                decimals: decimals_, adminVerified: false, exists: true
            });
        }
        emit TokenAddedToWatchlist(msg.sender, token);
    }

    /// @notice Remove a token from your personal watchlist
    function removeFromWatchlist(address token) external {
        require(inWatchlist[msg.sender][token], "Not watching");
        inWatchlist[msg.sender][token] = false;
        address[] storage list = userWatchlist[msg.sender];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == token) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        emit TokenRemovedFromWatchlist(msg.sender, token);
    }

    // ─────────────── VIEW ───────────────

    function getUserWatchlist(address user) external view returns (address[] memory) {
        return userWatchlist[user];
    }

    function getVerifiedTokens() external view returns (address[] memory) {
        return verifiedTokens;
    }

    function getTokenInfo(address token) external view returns (TokenInfo memory) {
        return tokenRegistry[token];
    }
}
