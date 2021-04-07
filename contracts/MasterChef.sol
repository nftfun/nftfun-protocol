// SPDX-License-Identifier: MIT

pragma solidity >=0.6.6;

import "./lib/SafeBEP20.sol";
import "./lib/SafeMathInt.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IFun {
    function master() external view returns (address);
}

interface IMaster {
    function lastTotalSupply() external view returns (uint256);
    function latestSupplyDelta() external returns (int256);
}


// MasterChef is the master of Fun. He can make Fun and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Fun is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of Funs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accFunPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accFunPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. Funs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that Funs distribution occurs.
        uint256 accFunPerShare;   // Accumulated Funs per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
        uint16 tokenType;
    }

    // The Fun TOKEN!
    address public fun;
    // Dev address.
    address public devaddr;
    // Fun tokens created per block.
    uint256 public funPerBlock;
    // Bonus muliplier for early fun makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Deposit Fee address
    address public feeAddress;

    uint256 public totalSupply;
    uint256 public devRate = 0;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when Fun mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 goosePerBlock);

    constructor(
        address _fun,
        address _devaddr,
        address _feeAddress,
        uint256 _funPerBlock,
        uint256 _startBlock
    ) public {
        fun = _fun;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        funPerBlock = _funPerBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IBEP20 => bool) public poolExistence;
    modifier nonDuplicated(IBEP20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    function addMintAmount(uint256 _amount) external nonReentrant {
        IBEP20(fun).transferFrom(msg.sender, address(this), _amount);
        totalSupply = totalSupply.add(_amount);
    }

    function sync() external nonReentrant {
        int256 supplyDelta = IMaster(IFun(fun).master()).latestSupplyDelta();
        if(supplyDelta == 0 || funPerBlock == 0 || totalSupply == 0) {
            return;
        }
        
        massUpdatePools();

        uint256 lastTotalSupply = IMaster(IFun(fun).master()).lastTotalSupply();
        if (supplyDelta < 0) {
            totalSupply = totalSupply.sub(uint256(supplyDelta.abs()).mul(totalSupply).div(lastTotalSupply));
            funPerBlock = funPerBlock.sub(uint256(supplyDelta.abs()).mul(funPerBlock).div(lastTotalSupply));
        } else {
            totalSupply = totalSupply.add(uint256(supplyDelta.abs()).mul(totalSupply).div(lastTotalSupply));
            funPerBlock = funPerBlock.add(uint256(supplyDelta.abs()).mul(funPerBlock).div(lastTotalSupply));
        }

        emit UpdateEmissionRate(msg.sender, funPerBlock);
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, bool _withUpdate, uint16 _tokenType) public onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(PoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardBlock : lastRewardBlock,
            accFunPerShare : 0,
            depositFeeBP : _depositFeeBP,
            tokenType: _tokenType
        }));
    }

    function batchAdd(bool _withUpdate, uint256[] memory _allocPoints, IBEP20[] memory _lpTokens, uint16[] memory _depositFeeBPs, uint16[] memory _tokenTypes) public onlyOwner {
        for(uint256 i; i<_allocPoints.length; i++) {
            add(_allocPoints[i], _lpTokens[i], _depositFeeBPs[i], false, _tokenTypes[i]);
        }
        if (_withUpdate) {
            massUpdatePools();
        }
    }

    // Update the given pool's Fun allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate, uint16 _tokenType) public onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].tokenType = _tokenType;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending Funs on frontend.
    function pendingFun(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accFunPerShare = pool.accFunPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 funReward = multiplier.mul(funPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accFunPerShare = accFunPerShare.add(funReward.mul(1e12).div(lpSupply));
        }
        uint256 result = user.amount.mul(accFunPerShare).div(1e12).sub(user.rewardDebt);
        if(result > IBEP20(fun).balanceOf(address(this))) {
            result = IBEP20(fun).balanceOf(address(this));
        }
        return result;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 funReward = multiplier.mul(funPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        if(devRate>0) {
            safeFunTransfer(devaddr, funReward.div(devRate));
        }
        pool.accFunPerShare = pool.accFunPerShare.add(funReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for Fun allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accFunPerShare).div(1e12).sub(user.rewardDebt);
            safeFunTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accFunPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accFunPerShare).div(1e12).sub(user.rewardDebt);
        safeFunTransfer(msg.sender, pending);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accFunPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function harvest(uint256 _pid) public {
        deposit(_pid, 0);
    }

    // Safe fun transfer function, just in case if rounding error causes pool to not have enough Funs.
    function safeFunTransfer(address _to, uint256 _amount) internal {
        uint256 funBal = IBEP20(fun).balanceOf(address(this));
        if(_amount > 0 && funBal > 0) {
            if (_amount > funBal) {
                IBEP20(fun).transfer(_to, funBal);
            } else {
                IBEP20(fun).transfer(_to, _amount);
            }
        }
    }

    // Update dev address by the previous dev.
    function changeDev(address _devaddr) public {
        require(msg.sender == devaddr || msg.sender == owner(), "changeDev: FORBIDDEN");
        devaddr = _devaddr;
        emit SetDevAddress(msg.sender, _devaddr);
    }

    function setDevRate(uint256 _value) public onlyOwner {
        require(_value >=0 && _value <=10, 'invalid param');
        devRate = _value;
    }

    function setStartBlock(uint256 _value) public onlyOwner {
        startBlock = _value;
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress || msg.sender == owner(), "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    //Fun has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _funPerBlock) public onlyOwner {
        massUpdatePools();
        funPerBlock = _funPerBlock;
        emit UpdateEmissionRate(msg.sender, _funPerBlock);
    }
}
