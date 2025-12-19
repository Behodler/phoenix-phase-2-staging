// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockPhUSD
 * @notice Mock ERC20 implementing IFlax minter interface with authorization
 * @dev For local testing only - simplified authorization model
 */
contract MockPhUSD is ERC20, Ownable {
    struct MinterInfo {
        bool canMint;
        uint256 mintVersion;
    }

    uint256 public mintVersion;
    mapping(address => MinterInfo) private _authorizedMinters;

    event MinterSet(address indexed minter, bool canMint, uint256 mintVersion);
    event AllMintPrivilegesRevoked(uint256 newVersion);

    constructor() ERC20("Phoenix USD", "phUSD") Ownable(msg.sender) {
        mintVersion = 1;
    }

    /**
     * @notice Authorize or revoke minter
     * @param minter Address to authorize/revoke
     * @param canMint True to authorize, false to revoke
     */
    function setMinter(address minter, bool canMint) external onlyOwner {
        _authorizedMinters[minter] = MinterInfo({
            canMint: canMint,
            mintVersion: mintVersion
        });
        emit MinterSet(minter, canMint, mintVersion);
    }

    /**
     * @notice Mint phUSD tokens (requires authorization)
     * @param recipient Address to receive minted tokens
     * @param amount Amount to mint
     */
    function mint(address recipient, uint256 amount) external {
        MinterInfo memory info = _authorizedMinters[msg.sender];
        require(info.canMint && info.mintVersion == mintVersion, "Not authorized to mint");
        _mint(recipient, amount);
    }

    /**
     * @notice Burn phUSD tokens from holder
     * @param holder Address to burn from
     * @param amount Amount to burn
     */
    function burn(address holder, uint256 amount) external {
        MinterInfo memory info = _authorizedMinters[msg.sender];
        require(info.canMint && info.mintVersion == mintVersion, "Not authorized to burn");
        _burn(holder, amount);
    }

    /**
     * @notice Check minter authorization
     * @param minter Address to check
     * @return MinterInfo struct with canMint and mintVersion
     */
    function authorizedMinters(address minter) external view returns (MinterInfo memory) {
        return _authorizedMinters[minter];
    }

    /**
     * @notice Revoke all minting privileges by incrementing version
     * @dev All existing minters must be re-authorized after this
     */
    function revokeAllMintPrivileges() external onlyOwner {
        mintVersion++;
        emit AllMintPrivilegesRevoked(mintVersion);
    }
}
