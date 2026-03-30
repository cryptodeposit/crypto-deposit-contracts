// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";


contract StableTokenUpgradeable is Initializable, ERC20Upgradeable, ERC20BurnableUpgradeable, ERC20PausableUpgradeable, AccessControlUpgradeable, OwnableUpgradeable, UUPSUpgradeable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    mapping(address => bool) public blacklisted;

    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);
    event BlackFundsDestroyed(address indexed account, uint256 amount);

    uint8 private _decimals;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply,
        address initialOwner
    ) public initializer {
        __ERC20_init(name_, symbol_);
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __AccessControl_init();
        __Ownable_init(initialOwner);

        _decimals = decimals_;

        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(MINTER_ROLE, initialOwner);
        _grantRole(PAUSER_ROLE, initialOwner);
        _grantRole(BLACKLISTER_ROLE, initialOwner);
        _grantRole(UPGRADER_ROLE, initialOwner);

        _mint(initialOwner, initialSupply * (10 ** decimals_));
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function mint(uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(owner(), amount);
    }

    function redeem(uint256 amount) public onlyRole(MINTER_ROLE) {
        _burn(owner(), amount);
    }

    // Override to restrict burning to minter role
    function burn(uint256 amount) public override onlyRole(MINTER_ROLE) {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyRole(MINTER_ROLE) {
        super.burnFrom(account, amount);
    }

    function addBlacklist(address account) public onlyRole(BLACKLISTER_ROLE) {
        require(account != address(0), "Invalid address");
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function removeBlacklist(address account) public onlyRole(BLACKLISTER_ROLE) {
        blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    function destroyBlackFunds(address account) public onlyRole(BLACKLISTER_ROLE) {
        require(blacklisted[account], "Not blacklisted");
        uint256 amount = balanceOf(account);
        _burn(account, amount);
        emit BlackFundsDestroyed(account, amount);
    }

    // Hook for pauses and blacklists
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable, ERC20PausableUpgradeable) {
        require(!blacklisted[from], "Sender blacklisted");
        require(!blacklisted[to], "Recipient blacklisted");
        super._update(from, to, value);
    }

    // UUPS upgrade authorization
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /// @dev Reserved storage space for future upgrades
    uint256[48] private __gap;
}
