// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./interfaces/ITravelRuleRegistry.sol";

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

contract TravelRuleRegistryUpgradeable is Initializable, ContextUpgradeable, AccessControlUpgradeable, UUPSUpgradeable, ITravelRuleRegistry {
    bytes32 public constant ORDERING_ROLE = keccak256("ORDERING_ROLE");
    bytes32 public constant INTERMEDIARY_ROLE = keccak256("INTERMEDIARY_ROLE");
    bytes32 public constant BENEFICIARY_ROLE = keccak256("BENEFICIARY_ROLE");
    bytes32 public constant POLICY_ADMIN_ROLE = keccak256("POLICY_ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct Policy {
        uint256 minAmount;
        bool alwaysOn;
        uint64 ttl;
    }
    mapping(address => Policy) public policyOf;

    enum Status { None, Ready, Consumed, Cancelled, Expired }
    struct Record {
        uint64 expiresAt;
        Status status;
        bytes32 payerHash;
        bytes32 payeeHash;
        bytes32 customerRefHash;
        address ordering;
    }
    mapping(bytes32 => Record) private _records;

    event PolicySet(address indexed token, uint256 minAmount, bool alwaysOn, uint64 ttl);
    event Precleared(bytes32 indexed key, address indexed token, address indexed payer, address payee, uint256 amount, uint64 expiresAt, address ordering);
    event Consumed(bytes32 indexed key);
    event Cancelled(bytes32 indexed key);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin) public initializer {
        require(admin != address(0), "admin=0");
        __Context_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POLICY_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    function setPolicy(address token, uint256 minAmount, bool alwaysOn, uint64 ttlSeconds) external onlyRole(POLICY_ADMIN_ROLE) {
        policyOf[token] = Policy({minAmount: minAmount, alwaysOn: alwaysOn, ttl: ttlSeconds});
        emit PolicySet(token, minAmount, alwaysOn, ttlSeconds);
    }

    function _key(address token, address from, address to, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(token, from, to, amount));
    }

    function preclear(
        address token,
        address payer,
        address payee,
        uint256 amount,
        bytes32 payerHash,
        bytes32 payeeHash,
        bytes32 customerRefHash
    ) external onlyRole(ORDERING_ROLE) returns (bytes32 key) {
        Policy memory p = policyOf[token];
        require(p.ttl > 0, "policy unset");

        key = _key(token, payer, payee, amount);
        Record storage r = _records[key];
        require(r.status == Status.None || r.status == Status.Expired || r.expiresAt < block.timestamp, "exists");

        uint64 expires = uint64(block.timestamp) + p.ttl;
        _records[key] = Record({
            expiresAt: expires,
            status: Status.Ready,
            payerHash: payerHash,
            payeeHash: payeeHash,
            customerRefHash: customerRefHash,
            ordering: _msgSender()
        });

        emit Precleared(key, token, payer, payee, amount, expires, _msgSender());
    }

    function cancel(bytes32 key) external {
        Record storage r = _records[key];
        require(r.status == Status.Ready, "not ready");
        require(_msgSender() == r.ordering || hasRole(ORDERING_ROLE, _msgSender()), "not ordering");
        r.status = Status.Cancelled;
        emit Cancelled(key);
    }

    function isCompliant(address token, address from, address to, uint256 amount) public view override returns (bool) {
        Policy memory p = policyOf[token];
        if (p.alwaysOn || amount >= p.minAmount) {
            bytes32 key = _key(token, from, to, amount);
            Record memory r = _records[key];
            if (r.status != Status.Ready) return false;
            if (r.expiresAt < block.timestamp) return false;
            return true;
        }
        return true;
    }
    /**
     * @notice Marks a precleared transfer as consumed when policy requires it.
     * @dev Does nothing if the amount is below the policy threshold. If a ready record is expired it is marked expired and the call reverts; otherwise the record must be ready and is set to consumed.
     */
    function consume(address token, address from, address to, uint256 amount) external override {
        Policy memory p = policyOf[token];
        if (p.alwaysOn || amount >= p.minAmount) {
            bytes32 key = _key(token, from, to, amount);
            Record storage r = _records[key];

            if (r.expiresAt < block.timestamp && r.status == Status.Ready) {
                r.status = Status.Expired;
                revert("travel: expired");
            }

            require(r.status == Status.Ready, "travel: missing");
            r.status = Status.Consumed;
            emit Consumed(key);
        }
    }

    /// @notice Get a travel rule record by key
    function getRecord(bytes32 key) external view returns (Record memory) {
        return _records[key];
    }

    /// @notice Compute the record key for a transfer
    function computeKey(address token, address from, address to, uint256 amount) external pure returns (bytes32) {
        return _key(token, from, to, amount);
    }

    /// @dev Reserved storage space for future upgrades
    uint256[48] private __gap;
}
