// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LToken — 存款凭证代币（类比 Compound 的 cToken）
 *
 * @dev 设计要点：
 *  - 只有 LendingPool 可以 mint / burn
 *  - 用户持有 lToken，代表在池子中的份额
 *  - lToken 不是 1:1 对应 borrowAsset，而是通过 exchangeRate 换算
 *  - exchangeRate 随时间增大（因借款人支付利息），这就是存款收益的来源
 */
contract LToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable pool; // 只有 pool 可以 mint/burn

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol, address _pool) {
        name = _name;
        symbol = _symbol;
        pool = _pool;
    }

    modifier onlyPool() {
        require(msg.sender == pool, "only pool");
        _;
    }

    function mint(address to, uint256 amount) external onlyPool {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyPool {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
