// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Oráculo mínimo de exemplo: contas autorizadas publicam valores por chave; qualquer um lê.
/// Serve para exercitar o ciclo de implantação na RBB (deploy, chamada, leitura). Não é um produto.
contract Oracle {
    struct Reading { int256 value; uint8 decimals; uint64 updatedAt; address source; }

    address public owner;
    mapping(address => bool) public updaters;
    mapping(bytes32 => Reading) private readings;

    event Updated(bytes32 indexed key, int256 value, uint8 decimals, address indexed source);
    event UpdaterSet(address indexed account, bool allowed);

    modifier onlyOwner() { require(msg.sender == owner, "Oracle: not owner"); _; }
    modifier onlyUpdater() { require(updaters[msg.sender] || msg.sender == owner, "Oracle: not updater"); _; }

    constructor() { owner = msg.sender; updaters[msg.sender] = true; }

    function setUpdater(address account, bool allowed) external onlyOwner {
        updaters[account] = allowed;
        emit UpdaterSet(account, allowed);
    }

    function update(bytes32 key, int256 value, uint8 decimals) external onlyUpdater {
        readings[key] = Reading(value, decimals, uint64(block.timestamp), msg.sender);
        emit Updated(key, value, decimals, msg.sender);
    }

    function get(bytes32 key) external view returns (int256 value, uint8 decimals, uint64 updatedAt, address source) {
        Reading memory r = readings[key];
        require(r.updatedAt != 0, "Oracle: no reading");
        return (r.value, r.decimals, r.updatedAt, r.source);
    }
}
