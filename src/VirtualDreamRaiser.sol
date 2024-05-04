// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title Virtual Dream Raiser
 * @author Niferu
 * @notice This contract is offering a decentralized and fully automated ecosystem to fund innovative projects or charity events.
 
 * @dev This implements Chainlink:
 * Price Feeds
 * Automation
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";

contract VirtualDreamRaiser is Ownable, ReentrancyGuard, AutomationCompatibleInterface {
    /// @dev Errors
    error VDR__ZeroAmount();
    error VDR__InvalidDream();
    error VDR__DreamExpired();
    error VDR__TransferFailed();
    error VDR__NotDreamCreator();
    error VDR__UpkeepNotNeeded();
    error VDR__CheckingStateFailed();
    error VDR__updateVDRewarderFailed();
    error VDR__InvalidAmountCheckBalance();

    /// @dev Enums
    enum VirtualDreamRewarderState {
        OPEN,
        CALCULATING
    }

    /// @dev Variables
    address private immutable i_VDRewarder;
    uint256 private immutable i_interval;
    uint256 private s_totalDreams;
    uint256 private s_prizePool;
    uint256 private s_lastTimeStamp;
    uint256 private s_VirtualDreamRaiserBalance;
    VirtualDreamRewarderState private s_state;

    /// @dev Structs
    struct Dream {
        address idToCreator;
        address idToWallet;
        uint256 idToTimeLeft;
        uint256 idToGoal;
        uint256 idToTotalGathered;
        uint256 idToBalance;
        string idToDescription;
        bool idToStatus;
        bool idToPromoted;
    }

    address payable[] private s_donators;
    address[] private s_walletsWhiteList;

    /// @dev Mappings
    mapping(uint256 => Dream) private s_dreams;

    /// @dev Events
    event DreamCreated(uint256 indexed target, string desc, uint256 indexed exp, address indexed wallet);
    event DreamPromoted(uint256 indexed id);
    event DreamExpired(uint256 indexed id);
    event DreamFunded(uint256 indexed id, uint256 indexed donate, uint256 indexed prize);
    event DreamRealized(uint256 indexed id, uint256 indexed amount);
    event WalletAddedToWhiteList(address wallet);
    event WalletRemovedFromWhiteList(address indexed wallet);
    event VirtualDreamRaiserFunded(uint256 donate, uint256 indexed prize);
    event VirtualDreamRaiserWithdrawal(uint256 amount);
    event VDRewarderUpdated(uint256 amount, address payable[] donators);

    /// @dev Constructor
    constructor(address owner, address rewarderAddress, uint256 interval) Ownable(owner) {
        i_VDRewarder = rewarderAddress;
        i_interval = interval;
        s_lastTimeStamp = block.timestamp;
    }

    //////////////////////////////////// @notice Virtual Dream Raiser External Functions ////////////////////////////////////

    /// @notice Creating dream event, which will be gathering funds for dream realization
    /// @param goal Target amount that creator of dream want to gather
    /// @param description Description of dream, which people are funding
    /// @param expiration Dream funds gathering period expressed in days
    /// @param organizatorWallet Address of wallet, which will be able to withdraw donated funds
    function createDream(uint256 goal, string calldata description, uint256 expiration, address organizatorWallet) external {
        Dream storage dream = s_dreams[s_totalDreams];

        uint256 timeUnit = 1 days;

        dream.idToCreator = msg.sender;
        dream.idToWallet = organizatorWallet;
        dream.idToTimeLeft = (block.timestamp + (expiration * timeUnit));
        dream.idToGoal = goal;
        dream.idToDescription = description;
        dream.idToStatus = true;

        for (uint wallets = 0; wallets < s_walletsWhiteList.length; wallets++) {
            if (organizatorWallet == s_walletsWhiteList[wallets]) {
                dream.idToPromoted = true;

                emit DreamPromoted(s_totalDreams);

                break;
            }
        }

        s_totalDreams += 1;

        emit DreamCreated(goal, description, expiration, organizatorWallet);
    }

    /// @notice Function, which allow users to donate for certain dream
    /// @param dreamId Unique identifier of dream
    function fundDream(uint256 dreamId) external payable {
        Dream storage dream = s_dreams[dreamId];
        if (msg.value <= 0) revert VDR__ZeroAmount();
        if (dreamId >= s_totalDreams) revert VDR__InvalidDream();
        if (dream.idToStatus == false) revert VDR__DreamExpired();

        uint256 donation = (msg.value * 49) / 50;
        uint256 prize = (msg.value * 1) / 50;

        s_prizePool += prize;
        s_donators.push(payable(msg.sender));
        dream.idToTotalGathered += donation;
        dream.idToBalance += donation;

        emit DreamFunded(dreamId, donation, prize);
    }

    /// @notice Function, which allows creator of dream event to withdraw funds
    /// @param dreamId Unique identifier of dream
    function realizeDream(uint256 dreamId) external nonReentrant {
        Dream storage dream = s_dreams[dreamId];
        if (dreamId >= s_totalDreams) revert VDR__InvalidDream();
        if (dream.idToCreator != msg.sender) revert VDR__NotDreamCreator();
        if (dream.idToBalance == 0) revert VDR__InvalidAmountCheckBalance();

        (bool success, ) = dream.idToWallet.call{value: dream.idToBalance}("");
        if (!success) revert VDR__TransferFailed();

        emit DreamRealized(dreamId, dream.idToBalance);

        dream.idToBalance = 0;
    }

    //////////////////////////////////// @notice Virtual Dream Raiser Internal Functions ////////////////////////////////////

    /// @notice Function, which will be called by Chainlink Keepers automatically always when dream event expire
    /// @param dreamId Unique identifier of dream
    function expireDream(uint256 dreamId) internal {
        Dream storage dream = s_dreams[dreamId];

        dream.idToStatus = false;
        s_lastTimeStamp = block.timestamp;

        emit DreamExpired(dreamId);
    }

    /// @notice Function, which will pass array of dreams funders and transfer prize pool to VirtualDreamRewarder contract
    /// @param virtualDreamRewarder VirtualDreamRewarder contract address, which will handle lottery for dreams funders
    function updateVDRewarder(address virtualDreamRewarder) internal {
        (bool success, ) = virtualDreamRewarder.call{value: s_prizePool}(abi.encodeWithSignature("updateVirtualDreamRewarder(address[])", s_donators));
        if (!success) revert VDR__updateVDRewarderFailed();

        emit VDRewarderUpdated(s_prizePool, s_donators);

        s_donators = new address payable[](0);
        s_prizePool = 0;
    }

    /// @notice Function, which is checking current state of VirtualDreamRewarder contract
    /// @param virtualDreamRewarder VirtualDreamRewarder contract address, which will handle lottery for dreams funders
    function getAndUpdateRewarderState(address virtualDreamRewarder) internal {
        (bool checkingState, bytes memory data) = virtualDreamRewarder.staticcall(abi.encodeWithSignature("getVirtualDreamRewarderState()"));
        if (!checkingState) revert VDR__CheckingStateFailed();
        VirtualDreamRewarderState state = abi.decode(data, (VirtualDreamRewarderState));
        if (state == VirtualDreamRewarderState.CALCULATING) {
            s_state = VirtualDreamRewarderState.CALCULATING;
        } else {
            s_state = VirtualDreamRewarderState.OPEN;
        }
    }

    //////////////////////////////////// @notice Virtual Dream Raiser Owners Functions ////////////////////////////////////

    /// @notice Function, which allow users to donate for VirtualDreamRaiser creators
    function fundVirtualDreamRaiser() external payable {
        if (msg.value <= 0) revert VDR__ZeroAmount();

        uint256 donation = (msg.value * 49) / 50;
        uint256 prize = (msg.value * 1) / 50;

        s_prizePool += prize;
        s_donators.push(payable(msg.sender));
        s_VirtualDreamRaiserBalance += donation;

        emit VirtualDreamRaiserFunded(donation, prize);
    }

    /// @notice Function, which allow VirtualDreamRaiser creators to witdraw their donates
    function withdrawDonates() external onlyOwner {
        if (s_VirtualDreamRaiserBalance <= 0) revert VDR__ZeroAmount();

        (bool success, ) = owner().call{value: s_VirtualDreamRaiserBalance}("");
        if (!success) revert VDR__TransferFailed();

        emit VirtualDreamRaiserWithdrawal(s_VirtualDreamRaiserBalance);

        s_VirtualDreamRaiserBalance = 0;
    }

    /// @notice Function, which allow VirtualDreamRaiser creators to add wallet to white list
    function addToWhiteList(address organizationWallet) external onlyOwner {
        s_walletsWhiteList.push(organizationWallet);

        emit WalletAddedToWhiteList(organizationWallet);
    }

    /// @notice Function, which allow VirtualDreamRaiser creators to remove wallet from white list
    function removeFromWhiteList(address organizationWallet) external onlyOwner {
        for (uint i = 0; i < s_walletsWhiteList.length; i++) {
            if (s_walletsWhiteList[i] == organizationWallet) {
                // Swapping wallet to be removed into last spot in array, so we can pop it and avoid getting 0 in array
                s_walletsWhiteList[i] = s_walletsWhiteList[s_walletsWhiteList.length - 1];
                s_walletsWhiteList.pop();

                emit WalletRemovedFromWhiteList(organizationWallet);
            }
        }
    }

    //////////////////////////////////// @notice Chainlink Keepers Functions ////////////////////////////////////

    /// @notice This is the function that the Chainlink Keeper nodes call to check if performing upkeep is needed
    /// @param upkeepNeeded returns true or false depending on x conditions
    function checkUpkeep(bytes memory /* checkData */) public view override returns (bool upkeepNeeded, bytes memory /* performData */) {
        bool timePassed = ((block.timestamp - s_lastTimeStamp) > i_interval);
        bool hasDreams = s_totalDreams > 0;
        bool hasFunders = false;
        bool hasPrizePool = false;

        if (s_donators.length > 0) {
            hasFunders = true;
        }

        if (s_prizePool > 0) {
            hasPrizePool = true;
        }

        upkeepNeeded = (timePassed && hasDreams && hasFunders && hasPrizePool);

        return (upkeepNeeded, "0x0");
    }

    /// @notice Once checkUpkeep() returns "true" this function is called to execute expireDream() and updateVDRewarder() functions
    function performUpkeep(bytes calldata /* performData */) external override {
        (bool upkeepNeeded, ) = checkUpkeep("");
        getAndUpdateRewarderState(i_VDRewarder);
        bool isRewarderOpen = false;
        bool hasDreamsToExpire = false;

        if (s_state == VirtualDreamRewarderState.OPEN) {
            isRewarderOpen = true;
        }

        if (!upkeepNeeded || !isRewarderOpen) revert VDR__UpkeepNotNeeded();

        for (uint dreamId = 0; dreamId < s_totalDreams; dreamId++) {
            Dream storage dream = s_dreams[dreamId];

            if (dream.idToStatus == true) {
                if (dream.idToTimeLeft < block.timestamp) {
                    hasDreamsToExpire = true;
                    break;
                }
            }
        }

        if (hasDreamsToExpire) {
            for (uint dreamId = 0; dreamId < s_totalDreams; dreamId++) {
                Dream storage dream = s_dreams[dreamId];

                if (dream.idToTimeLeft < block.timestamp) {
                    expireDream(dreamId);
                    updateVDRewarder(i_VDRewarder);
                }
            }
        } else {
            updateVDRewarder(i_VDRewarder);
        }
    }

    //////////////////////////////////// @notice Getters ////////////////////////////////////

    function getTotalDreams() external view returns (uint256) {
        return s_totalDreams;
    }

    function getCreator(uint256 dreamId) external view returns (address) {
        Dream storage dream = s_dreams[dreamId];

        return dream.idToCreator;
    }

    function getWithdrawWallet(uint256 dreamId) external view returns (address) {
        Dream storage dream = s_dreams[dreamId];

        return dream.idToWallet;
    }

    function getTimeLeft(uint256 dreamId) external view returns (uint256) {
        Dream storage dream = s_dreams[dreamId];

        return (dream.idToTimeLeft < block.timestamp) ? 0 : (dream.idToTimeLeft - block.timestamp);
    }

    function getGoal(uint256 dreamId) external view returns (uint256) {
        Dream storage dream = s_dreams[dreamId];

        return dream.idToGoal;
    }

    function getTotalGathered(uint256 dreamId) external view returns (uint256) {
        Dream storage dream = s_dreams[dreamId];

        return dream.idToTotalGathered;
    }

    function getDreamBalance(uint256 dreamId) external view returns (uint256) {
        Dream storage dream = s_dreams[dreamId];

        return dream.idToBalance;
    }

    function getDescription(uint256 dreamId) external view returns (string memory) {
        Dream storage dream = s_dreams[dreamId];

        return dream.idToDescription;
    }

    function getStatus(uint256 dreamId) external view returns (bool) {
        Dream storage dream = s_dreams[dreamId];

        return dream.idToStatus;
    }

    function getPromoted(uint256 dreamId) external view returns (bool) {
        Dream storage dream = s_dreams[dreamId];

        return dream.idToPromoted;
    }

    function getWhiteWalletsList() external view returns (address[] memory) {
        return s_walletsWhiteList;
    }

    function getPrizePool() external view returns (uint256) {
        return s_prizePool;
    }

    function getNewPlayers() external view returns (address payable[] memory) {
        return s_donators;
    }

    function getVirtualDreamRaiserBalance() external view returns (uint256) {
        return s_VirtualDreamRaiserBalance;
    }

    function getVDRewarder() external view returns (address) {
        return i_VDRewarder;
    }
}
