// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";


contract ICO is ReentrancyGuard,Ownable,AccessControl{

    using SafeERC20 for IERC20;
    using SafeMath for uint;

    struct UserDepositInfo {
        uint256 amountDepositedUsdt; // Total usdt amount deposited by the user
        uint256 amountDepositedEth; // Total ETH amount deposited by the user
        uint256 purchasedTokens; // Total tokens purchased by the user
    }

    struct Presale {
        uint256 startTime;    // Sale start time
        uint256 endTime;      // Sale endtime
        uint256 price;        // per Tan price
        uint256 tokenToSell;  // 10 billion
        uint256 tokenPerUSD;   // 500 TAN
        uint256 tokenSold;
        bool enableBuyWithEth;
        bool enableBuyWithUsdt;
    }

    struct ThresholdBonus {
       uint256 threshold;   // Threshold amount in USD
       uint256 bonusPercent; // Bonus percentage
    }

    mapping(address => mapping(uint256 =>UserDepositInfo)) public userDeposits;
    mapping(uint256 => Presale) public presale;
    mapping(uint256 => bool) public paused;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    uint256 public presaleId;
    uint256 public maxTotalFunds;
    uint256 public totalFundsCollected;
    ThresholdBonus[] public bonusThresholds;

    address private immutable treasury;
    IERC20 public immutable USDT;
    AggregatorV3Interface internal aggregatorInterface; // https://docs.chain.link/docs/ethereum-addresses/ => (ETH / USD)
    
    event PresaleCreated( uint256 indexed _id, uint256 _totalTokens, uint256 _tokenPrice, uint256 _tokenPerUSD, uint256 _startTime, uint256 _endTime, bool enableBuyWithEth,  bool enableBuyWithUsdt);  
    event PresaleUpdated( bytes32 indexed key, uint256 prevValue, uint256 newValue, uint256 timestamp );
    event Deposited(uint indexed _id, address indexed user, uint256 _amount, bool _isUsdt, uint256 _timestamp);
    event PresalePaused(uint256 indexed id, uint256 timestamp);
    event PresaleUnpaused(uint256 indexed id, uint256 timestamp);
   
    constructor(
        address _admin,
        address _operator,
        address _treasury,  
        IERC20  _usdt,
        address _oracle
     )Ownable(msg.sender){
         require(
            (_admin != address(0)) && (_operator != address(0))&& (_treasury != address(0)) && (address(_usdt) != address(0)) && ( _oracle != address(0))
         );
          treasury = _treasury;
          USDT = _usdt;
          aggregatorInterface = AggregatorV3Interface(_oracle);

        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);

        bonusThresholds.push(ThresholdBonus(300 * 1e6, 100));  // $300 -> 10% bonus
        bonusThresholds.push(ThresholdBonus(500 * 1e6, 150));  // $500 -> 15% bonus
        bonusThresholds.push(ThresholdBonus(700 * 1e6, 200));  // $700 -> 20% bonus

    }

    modifier onlyAdmin() {
      require(hasRole(ADMIN_ROLE, msg.sender), "AccessControl: must have ADMIN_ROLE");
      _;
    }

    modifier onlyOperator() {
      require(hasRole(OPERATOR_ROLE, msg.sender), "AccessControl: must have OPERATOR_ROLE");
      _;
    }

    modifier checkPresaleId(uint256 _id) {
        require(_id > 0 && _id <= presaleId, "Invalid presale id");
        _;
    }

    modifier checkSaleState(uint256 _id, uint256 amount) {
        require( block.timestamp >= presale[_id].startTime &&
                 block.timestamp <= presale[_id].endTime,
                 "Invalid time for buying"
        );
        require(
            amount > 0 && amount <= presale[_id].tokenToSell.sub(presale[_id].tokenSold),
            "Invalid sale amount"
        );
        _;
    }

    function pausePresale(uint256 _id) external checkPresaleId(_id) onlyOwner {
        require(!paused[_id], "Already paused");
        paused[_id] = true;
        emit PresalePaused(_id, block.timestamp);
    }

    function unPausePresale(uint256 _id) external checkPresaleId(_id) onlyOwner {
        require(paused[_id], "Not paused");
        paused[_id] = false;
        emit PresaleUnpaused(_id, block.timestamp);
    }

    function createPresale(uint256 _startTime, uint256 _endTime, uint256 _tokenPrice, uint256 _totalTokensToSell, bool _buyWithETH, bool _buyWithUSDT) external onlyOperator {
      require(
            _startTime > block.timestamp && _endTime > _startTime,
            "Invalid time"
        );
        require(_tokenPrice > 0, "Zero price");
        require(_totalTokensToSell > 0, "Zero tokens to sell");
        presaleId++;

            uint256 valueWith6Decimals = _tokenPrice.div(10e11) ;
            uint256 tokenPerUSD =  10e5;
            tokenPerUSD = (tokenPerUSD).div(valueWith6Decimals);

        presale[presaleId] = Presale(
            _startTime,
            _endTime,
            valueWith6Decimals,
            _totalTokensToSell,
             tokenPerUSD,
            0,
            _buyWithETH,
            _buyWithUSDT
        );

        emit PresaleCreated(presaleId, _totalTokensToSell,_tokenPrice,tokenPerUSD, _startTime, _endTime, _buyWithETH, _buyWithUSDT);
    }

    function Deposit(uint _id, uint _amount, bool isUSDT) external payable checkPresaleId(_id) checkSaleState(_id, _amount) nonReentrant returns (bool) {   
       require(!paused[_id], "Presale paused");
       require(_amount > 0,"Amount Should be greater than Zero");

        uint256 totalTokens;
        
        uint256 leftToken = presale[_id].tokenToSell - presale[_id].tokenSold;
        UserDepositInfo storage userDepositInfo = userDeposits[msg.sender][_id];

        if(isUSDT){
            require(presale[_id].enableBuyWithUsdt, "Not allowed to buy with USDT");
            (, ,  totalTokens)  = calculateBonus(_id, _amount, isUSDT);
            require(leftToken >= totalTokens, "Not enough tokens left");

            USDT.safeTransferFrom(msg.sender, treasury, _amount);
            userDepositInfo.amountDepositedUsdt = userDepositInfo.amountDepositedUsdt.add(_amount);

        }else{
            require(presale[_id].enableBuyWithEth, "Not allowed to buy with ETH");
            require(_amount == msg.value,"Amount must be same ");
            uint256 ethToUsdt = calculateEthToUsd(_amount);
            (, ,  totalTokens) = calculateBonus(_id, ethToUsdt,isUSDT);
            require(leftToken >= totalTokens, "Not enough tokens left");

            (bool success, ) = treasury.call{value: _amount}("");
            require(success, "ETH transfer failed");

             userDepositInfo.amountDepositedEth = userDepositInfo.amountDepositedEth.add(_amount);

        }
           presale[_id].tokenSold = (presale[_id].tokenSold).add(totalTokens);
           userDepositInfo.purchasedTokens = userDepositInfo.purchasedTokens.add(totalTokens);

        emit Deposited( _id, msg.sender,  _amount,  isUSDT, block.timestamp);

        return true;

    }

    function changeSaleTimes(uint256 _id, uint256 _startTime, uint256 _endTime) external checkPresaleId(_id) onlyOperator {
        require(_startTime > 0 || _endTime > 0, "Invalid parameters");
        if (_startTime > 0) {
            require(  block.timestamp < presale[_id].startTime, "Sale already started" );
            require(block.timestamp < _startTime, "Sale time in past");
            uint256 prevValue = presale[_id].startTime;
            presale[_id].startTime = _startTime;

            emit PresaleUpdated( bytes32("START"), prevValue, _startTime, block.timestamp );
        }

        if (_endTime > 0) {
            require(block.timestamp < presale[_id].endTime,"Sale already ended");
            require(_endTime > presale[_id].startTime, "Invalid endTime");
            uint256 prevValue = presale[_id].endTime;
            presale[_id].endTime = _endTime;

            emit PresaleUpdated( bytes32("END"), prevValue, _endTime, block.timestamp );
        }
    }

    function changePrice(uint256 _id, uint256 _newPrice)  external checkPresaleId(_id) onlyOperator {
        require(_newPrice > 0, "Zero price");
        require(  presale[_id].startTime > block.timestamp, "Sale already started" );
        uint256 prevValue = presale[_id].price;

        uint256 valueWith6Decimals = _newPrice.div(1e12) ;
        presale[_id].price = valueWith6Decimals;
        uint256 tokenPerUSD =  1e6;
        presale[_id].tokenPerUSD = (tokenPerUSD).div(valueWith6Decimals);

        emit PresaleUpdated(bytes32("PRICE"), prevValue, valueWith6Decimals, block.timestamp );
    }

      /**
      * @dev To update the possibility to buy with ETH or USDT
      * @param _id Presale id to update
      * @param _paymentMethod 0 for ETH, 1 for USDT
      * @param _enable Boolean value: `true` to enable, `false` to disable
      */
    function changeEnableBuyWith(uint256 _id, uint256 _paymentMethod, bool _enable) external checkPresaleId(_id) onlyOperator {
        bool prevValue;

         // Check for ETH (0) or USDT (1)
       if (_paymentMethod == 0) {
          prevValue = presale[_id].enableBuyWithEth;
          presale[_id].enableBuyWithEth = _enable;

          emit PresaleUpdated( bytes32("ENABLE_BUY_WITH_ETH"), prevValue ? 1 : 0, _enable ? 1 : 0, block.timestamp );
       } else if (_paymentMethod == 1) {
          prevValue = presale[_id].enableBuyWithUsdt;
          presale[_id].enableBuyWithUsdt = _enable;

        emit PresaleUpdated( bytes32("ENABLE_BUY_WITH_USDT"), prevValue ? 1 : 0, _enable ? 1 : 0, block.timestamp );
       } else {
           revert("Invalid payment method. Use 0 for ETH or 1 for USDT");
       }
    }

    function getLatestPrice() private view returns (uint256) {
        (, int256 price, , , ) = aggregatorInterface.latestRoundData();
        return uint256(price).mul(1e10);
    }

    function calculateEthToUsd(uint256 _amount)public view returns(uint){
        uint256 ethUsd = getLatestPrice();
        uint256 amountUSD = (_amount * ethUsd).div(1e18);
        return  amountUSD;
    }

    function calculateBonus(uint _id, uint256 amountDeposited, bool isUSDT) public view returns (uint256 extraAmount, uint256 bonusAmount, uint256 totalTokens) {
         bonusAmount = 0;
         extraAmount = 0;
         totalTokens = 0;

        uint256 thresholdFactor = isUSDT ? 1 : 1e12;  // 1e12 for ETH, no factor for USDT

            for (uint256 i = 0; i < bonusThresholds.length; i++) {    
                uint256 threshold = bonusThresholds[i].threshold.mul(thresholdFactor);
              if (amountDeposited >= threshold) {
               extraAmount = (amountDeposited.sub(threshold));         
               uint256 bonusToken = (presale[_id].tokenPerUSD).mul(bonusThresholds[i].bonusPercent).div(1000);
               uint256 bonusPerUSD = (presale[_id].tokenPerUSD).add(bonusToken);

              bonusAmount = extraAmount.mul(bonusPerUSD); 
              }
            }

        totalTokens = calculateTotalTokens(_id, amountDeposited,extraAmount, bonusAmount, isUSDT);
    }

    function calculateTotalTokens(uint _id, uint256 amountUSD, uint256 extraAmount, uint256 bonusToken,bool isUSDT) private view returns (uint256) {
    
            uint256 amountForTokens = amountUSD.sub(extraAmount);
            uint256 tokenAmount = amountForTokens.mul(presale[_id].tokenPerUSD);
            uint256 totalTokens = tokenAmount.add(bonusToken);

           return isUSDT ? totalTokens.div(1e6) : totalTokens.div(1e18);
    }

    function updateThresholdBonus(uint256 _threshold, uint256 _bonusPercent, bool _isUpdate, uint256 _thresholdIndex) external onlyAdmin {
     require(_bonusPercent > 0, "Bonus percentage must be greater than 0");
    
     if (_isUpdate) {
        require(_thresholdIndex < bonusThresholds.length, "Invalid threshold index");
        
        ThresholdBonus storage bonus = bonusThresholds[_thresholdIndex];
        bonus.threshold = _threshold;
        bonus.bonusPercent = _bonusPercent;

        emit PresaleUpdated(bytes32("BONUS_THRESHOLD"), bonus.threshold, _threshold, block.timestamp);
        emit PresaleUpdated(bytes32("BONUS_PERCENTAGE"), bonus.bonusPercent, _bonusPercent, block.timestamp);
     } else {
        require(bonusThresholds.length == 0 || _threshold > bonusThresholds[bonusThresholds.length - 1].threshold, "Threshold must be greater than the last threshold");

        bonusThresholds.push(ThresholdBonus({
            threshold: _threshold,
            bonusPercent: _bonusPercent
        }));

        emit PresaleUpdated(bytes32("BONUS_THRESHOLD"), 0, _threshold, block.timestamp);
        emit PresaleUpdated(bytes32("BONUS_PERCENTAGE"), 0, _bonusPercent, block.timestamp);
     }
    }

    function withdraw(bool _isETH) external onlyAdmin {
        if (_isETH) {
            uint256 ethBalance = address(this).balance;
            require(ethBalance > 0, "No ETH to withdraw");
            (bool success, ) = treasury.call{value: ethBalance}("");
            require(success, "ETH withdrawal failed");
        } else {
            uint256 usdtBalance = USDT.balanceOf(address(this));
            require(usdtBalance > 0, "No USDT to withdraw");
            USDT.safeTransfer(treasury, usdtBalance);
        }
    }
}