// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@boringcrypto/boring-solidity/contracts/libraries/BoringMath.sol";
import "@boringcrypto/boring-solidity/contracts/BoringBatchable.sol";
import "@boringcrypto/boring-solidity/contracts/BoringOwnable.sol";
import "./libraries/SignedSafeMath.sol";

contract IchiFarmV2 is BoringOwnable, BoringBatchable {
    using BoringMath for uint256;
    using BoringMath128 for uint128;
    using BoringERC20 for IERC20;
    using SignedSafeMath for int256;

    /// @notice Info of each IFV2 user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of ICHI entitled to the user.
    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
    }

    /// @notice Info of each IFV2 pool.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of ICHI to distribute per block.
    struct PoolInfo {
        uint128 accIchiPerShare;
        uint64 lastRewardBlock;
        uint64 allocPoint;
    }

    /// @notice Address of ICHI contract.
    IERC20 public immutable ICHI;

    /// @notice Info of each IFV2 pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each IFV2 pool.
    IERC20[] public lpToken;

    /// @notice Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 totalAllocPoint;

    /// @notice ICHI tokens created per block.
    uint256 public ichiPerBlock;

    uint256 private constant ACC_ICHI_PRECISION = 1e18;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogPoolAddition(uint256 indexed pid, uint256 allocPoint, IERC20 indexed lpToken);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint);
    event LogUpdatePool(uint256 indexed pid, uint64 lastRewardBlock, uint256 lpSupply, uint256 accIchiPerShare);

    /// @param _ichi The ICHI token contract address.
    /// @param _ichiPerBlock ICHI tokens created per block.
    constructor(IERC20 _ichi, uint256 _ichiPerBlock) public {
        ICHI = _ichi;
        ichiPerBlock = _ichiPerBlock;
        totalAllocPoint = 0;
    }

    /// @notice Update number of ICHI tokens created per block. Can only be called by the owner.
    /// @param _ichiPerBlock ICHI tokens created per block.
    /// @param _withUpdate true if massUpdatePools should be triggered as well.
    function setIchiPerBlock(uint256 _ichiPerBlock, bool _withUpdate) public onlyOwner {
        ichiPerBlock = _ichiPerBlock;
        if (_withUpdate) {
            massUpdateAllPools();
        }
    }

    /// @notice Returns the number of IFV2 pools.
    function poolLength() external view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Returns the ICHI reward value for a specific pool.
    function ichiReward(uint256 _pid) external view returns (uint256) {
        return ichiPerBlock.mul(poolInfo[_pid].allocPoint).div(totalAllocPoint);
    }

    /// @notice Returns the total number of LPs staked in the farm.
    function getLPSupply(uint256 _pid) external view returns (uint256) {
        uint256 lpSupply = lpToken[_pid].balanceOf(address(this));
        return lpSupply;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param allocPoint AP of the new pool.
    /// @param _lpToken Address of the LP ERC-20 token.
    function add(uint256 allocPoint, IERC20 _lpToken) public onlyOwner {
        uint256 lastRewardBlock = block.number;
        totalAllocPoint = totalAllocPoint.add(allocPoint);
        lpToken.push(_lpToken);

        poolInfo.push(PoolInfo({
            allocPoint: allocPoint.to64(),
            lastRewardBlock: lastRewardBlock.to64(),
            accIchiPerShare: 0
        }));
        emit LogPoolAddition(lpToken.length.sub(1), allocPoint, _lpToken);
    }

    /// @notice Update the given pool's ICHI allocation point. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOwner {
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint.to64();
        emit LogSetPool(_pid, _allocPoint);
    }

    /// @notice View function to see pending ICHI on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending ICHI reward for a given user.
    function pendingIchi(uint256 _pid, address _user) external view returns (uint256 pending) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accIchiPerShare = pool.accIchiPerShare;
        uint256 lpSupply = lpToken[_pid].balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 blocks = block.number.sub(pool.lastRewardBlock);
            uint256 ichiReward = blocks.mul(ichiPerBlock.mul(pool.allocPoint) / totalAllocPoint;
            accIchiPerShare = accIchiPerShare.add(ichiReward.mul(ACC_ICHI_PRECISION) / lpSupply);
        }
        pending = int256(user.amount.mul(accIchiPerShare) / ACC_ICHI_PRECISION).sub(user.rewardDebt).toUInt256();
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    function massUpdateAllPools() external {
        uint256 len = poolInfo.length;
        for (uint256 pid = 0; pid < len; ++pid) {
            updatePool(pid);
        }
    }

    /// @notice Update reward variables for specified pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        if (block.number > pool.lastRewardBlock) {
            uint256 lpSupply = lpToken[pid].balanceOf(address(this));
            if (lpSupply > 0) {
                uint256 blocks = block.number.sub(pool.lastRewardBlock);
                uint256 ichiReward = blocks.mul(ichiPerBlock.mul(pool.allocPoint) / totalAllocPoint;
                pool.accIchiPerShare = pool.accIchiPerShare.add((ichiReward.mul(ACC_ICHI_PRECISION) / lpSupply).to128());
            }
            pool.lastRewardBlock = block.number.to64();
            poolInfo[pid] = pool;
            emit LogUpdatePool(pid, pool.lastRewardBlock, lpSupply, pool.accIchiPerShare);
        }
    }

    /// @notice Deposit LP tokens to IFV2 for ICHI allocation.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to deposit.
    /// @param to The receiver of `amount` deposit benefit.
    function deposit(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][to];

        // Effects
        user.amount = user.amount.add(amount);
        user.rewardDebt = user.rewardDebt.add(int256(amount.mul(pool.accIchiPerShare) / ACC_ICHI_PRECISION));

        // Interactions
        lpToken[pid].safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, pid, amount, to);
    }

    /// @notice Withdraw LP tokens from IFV2.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens.
    function withdraw(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];

        // Effects
        user.rewardDebt = user.rewardDebt.sub(int256(amount.mul(pool.accIchiPerShare) / ACC_ICHI_PRECISION));
        user.amount = user.amount.sub(amount);

        // Interactions
        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
    }

    /// @notice Safe ichi transfer function, just in case if rounding error causes pool to not have enough ICHIs.
    function safeIchiTransfer(address _to, uint256 _amount) internal {
        uint256 ichiBal = ICHI.balanceOf(address(this));
        if (_amount > ichiBal) {
            ICHI.transfer(_to, ichiBal);
        } else {
            ICHI.transfer(_to, _amount);
        }
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of ICHI rewards.
    function harvest(uint256 pid, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedIchi = int256(user.amount.mul(pool.accIchiPerShare) / ACC_ICHI_PRECISION);
        uint256 _pendingIchi = accumulatedIchi.sub(user.rewardDebt).toUInt256();
        if (_pendingIchi == 0) { success = false; }

        // Effects
        user.rewardDebt = accumulatedIchi;

        // Interactions
        safeIchiTransfer(to, _pendingIchi);

        emit Harvest(msg.sender, pid, _pendingIchi);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of the LP tokens.
    function emergencyWithdraw(uint256 pid, address to) public {
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        // Note: transfer can fail or succeed if `amount` is zero.
        lpToken[pid].safeTransfer(to, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount, to);
    }
}