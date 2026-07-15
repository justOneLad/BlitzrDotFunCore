// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Script, console} from "forge-std/Script.sol";

type Currency is address;
type BalanceDelta is int256;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24   fee;
    int24    tickSpacing;
    address  hooks;
}

struct ModifyLiquidityParams {
    int24   tickLower;
    int24   tickUpper;
    int256  liquidityDelta;
    bytes32 salt;
}

interface IPoolManager {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);
    function unlock(bytes calldata data) external returns (bytes memory);
    function sync(Currency currency) external;
    function settle() external payable returns (uint256 paid);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

// Minimal mintable ERC20 standing in for a real quote token (e.g. USDC), so we can seed a real
// native/quoteToken V4 reference pool on the fork without needing to locate exact real-world
// pool parameters for an existing mainnet pair.
contract MockQuoteToken {
    string public constant name = "Mock Quote";
    string public constant symbol = "MQT";
    uint8  public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// Creates a plain (no-hook) native/MockQuoteToken V4 pool with real two-sided liquidity, to
// serve as the reference pool for testing XBlitzrLauncher's multi-hop instant buy. Settles
// exactly whatever modifyLiquidity reports as owed, rather than pre-guessing amounts, since a
// wide two-sided range's required amounts aren't something the caller gets to just pick.
contract RefPoolSeeder is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable quoteToken;

    constructor(address poolManager_, address quoteToken_) {
        poolManager = IPoolManager(poolManager_);
        quoteToken = quoteToken_;
    }

    function seed(int24 tickLower, int24 tickUpper, int256 liquidityDelta) external payable {
        poolManager.unlock(abi.encode(tickLower, tickUpper, liquidityDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (int24 tickLower, int24 tickUpper, int256 liquidityDelta) = abi.decode(data, (int24, int24, int256));

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(address(0)),
            currency1:   Currency.wrap(quoteToken),
            fee:         3000,
            tickSpacing: 60,
            hooks:       address(0)
        });

        poolManager.initialize(key, 79228162514264337593543950336); // sqrtPriceX96 for price = 1

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      tickLower,
                tickUpper:      tickUpper,
                liquidityDelta: liquidityDelta,
                salt:           bytes32(0)
            }),
            ""
        );

        int128 amt0;
        int128 amt1;
        assembly {
            amt0 := sar(128, callerDelta)
            amt1 := signextend(15, callerDelta)
        }

        if (amt0 < 0) {
            poolManager.settle{value: uint256(uint128(-amt0))}();
        }
        if (amt1 < 0) {
            poolManager.sync(Currency.wrap(quoteToken));
            MockQuoteToken(quoteToken).transfer(address(poolManager), uint256(uint128(-amt1)));
            poolManager.settle();
        }

        return "";
    }

    receive() external payable {}
}

contract SetupRefPool is Script {
    function run() external returns (address quoteToken, address seeder) {
        address poolManager = vm.envAddress("POOL_MANAGER");

        vm.startBroadcast();
        MockQuoteToken token = new MockQuoteToken();
        token.mint(msg.sender, 1_000_000e18);

        RefPoolSeeder s = new RefPoolSeeder(poolManager, address(token));
        token.transfer(address(s), 1_000_000e18);
        s.seed{value: 100 ether}(-887220, 887220, int256(uint256(100e18)));
        vm.stopBroadcast();

        quoteToken = address(token);
        seeder = address(s);
        console.log("MockQuoteToken:");
        console.logAddress(quoteToken);
    }
}
