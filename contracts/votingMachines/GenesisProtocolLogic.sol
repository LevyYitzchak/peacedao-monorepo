pragma solidity ^0.4.25;

import "./IntVoteInterface.sol";
import { RealMath } from "../libs/RealMath.sol";
import "./VotingMachineCallbacksInterface.sol";
import "./ProposalExecuteInterface.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/math/Math.sol";
import "openzeppelin-solidity/contracts/token/ERC20/StandardToken.sol";
import "openzeppelin-solidity/contracts/AddressUtils.sol";



/**
 * @title GenesisProtocol implementation -an organization's voting machine scheme.
 */
contract GenesisProtocolLogic is IntVoteInterface {
    using SafeMath for uint;
    using Math for uint;
    using RealMath for int216;
    using RealMath for int256;
    using AddressUtils for address;

    enum ProposalState { None ,ExpiredInQueue, Executed, Queued ,PreBoosted,Boosted,QuietEndingPeriod }
    enum ExecutionState { None, QueueBarCrossed,QueueTimeOut,PreBoostedBarCrossed, BoostedTimeOut,BoostedBarCrossed }

    //Organization's parameters
    struct Parameters {
        uint queuedVoteRequiredPercentage; // the absolute vote percentages bar.
        uint queuedVotePeriodLimit; //the time limit for a proposal to be in an absolute voting mode.
        uint boostedVotePeriodLimit; //the time limit for a proposal to be in boost mode.
        uint preBoostedVotePeriodLimit; //the time limit for a proposal to be in an preparation state (stable) before boosted.
        int thresholdConst; //constant  for threshold calculation . threshold =thresholdConst ** (numberOfBoostedProposals)
        uint limitExponentValue;//// an upper limit for numberOfBoostedProposals in the threshold calculation to prevent overflow
        uint quietEndingPeriod; //quite ending period
        uint proposingRepReward;//proposer reputation reward.
        uint votersReputationLossRatio;//Unsuccessful pre booster voters lose votersReputationLossRatio% of their reputation.
        uint minimumDaoBounty;
        uint daoBountyConst;
        uint activationTime;//the point in time after which proposals can be created.
        address voteOnBehalf; //if this address is set so only this address is allowed to vote of behalf of someone else.
    }
    struct Voter {
        uint vote; // YES(1) ,NO(2)
        uint reputation; // amount of voter's reputation
        bool preBoosted;
    }

    struct Staker {
        uint vote; // YES(1) ,NO(2)
        uint amount; // amount of staker's stake
        uint amount4Bounty;// amount of staker's stake used for bounty reward calculation.
    }

    struct Proposal {
        bytes32 organizationId; // the organization unique identifier the proposal is target to.
        address callbacks;    // should fulfill voting callbacks interface.
        ProposalState state;
        uint winningVote; //the winning vote.
        address proposer;
        uint currentBoostedVotePeriodLimit;//the proposal boosted period limit . it is updated for the case of quiteWindow mode.
        bytes32 paramsHash;
        uint daoBountyRemain; //use for checking sum zero bounty claims.it is set at the proposing time.
        uint daoBounty;
        uint totalStakes;// totalStakes[0] - (amount staked minus fee) - Total number of tokens staked which can be redeemable by stakers.
                           // totalStakes[1] - (amount staked) - Total number of redeemable tokens.
        uint confidenceThreshold;
        uint expirationCallBountyPercentage;//The percentage from upper stakes which the caller for the expiration was given.
        uint[3] times; //times[0] - submittedTime
                       //times[1] - boostedPhaseTime
                       //times[2] -preBoostedPhaseTime;
        //      vote      reputation
        mapping(uint    =>  uint     ) votes;
        //      vote      reputation
        mapping(uint    =>  uint     ) preBoostedVotes;
        //      address     voter
        mapping(address =>  Voter    ) voters;
        //      vote        stakes
        mapping(uint    =>  uint     ) stakes;
        //      address  staker
        mapping(address  => Staker   ) stakers;
    }

    event Stake(bytes32 indexed _proposalId, address indexed _organization, address indexed _staker,uint _vote,uint _amount);
    event Redeem(bytes32 indexed _proposalId, address indexed _organization, address indexed _beneficiary,uint _amount);
    event RedeemDaoBounty(bytes32 indexed _proposalId, address indexed _organization, address indexed _beneficiary,uint _amount);
    event RedeemReputation(bytes32 indexed _proposalId, address indexed _organization, address indexed _beneficiary,uint _amount);
    event GPExecuteProposal(bytes32 indexed _proposalId, ExecutionState _executionState);
    event ExpirationCallBounty(bytes32 indexed _proposalId, address indexed _beneficiary,uint _amount);

    mapping(bytes32=>Parameters) public parameters;  // A mapping from hashes to parameters
    mapping(bytes32=>Proposal) public proposals; // Mapping from the ID of the proposal to the proposal itself.
    mapping(bytes32=>uint) public orgBoostedProposalsCnt;
           //organizationId => organization
    mapping(bytes32        => address     ) public organizations;
    //organizationId => averageBoostDownstakes
    mapping(bytes32           => uint               ) public averagesDownstakesOfBoosted;
    uint constant public NUM_OF_CHOICES = 2;
    uint constant public NO = 2;
    uint constant public YES = 1;
    uint public proposalsCnt; // Total number of proposals
    StandardToken public stakingToken;
    address constant GEN_TOKEN_ADDRESS = 0x543Ff227F64Aa17eA132Bf9886cAb5DB55DCAddf;

    /**
     * @dev Constructor
     */
    constructor(StandardToken _stakingToken) public
    {
      //The GEN token (staking token) address is hard coded in the contract by GEN_TOKEN_ADDRESS .
      //This will work for a network which already hosted the GEN token on this address (e.g mainnet).
      //If such contract address does not exist in the network (e.g ganache) the contract will use the _stakingToken param as the
      //staking token address.
        if (address(GEN_TOKEN_ADDRESS).isContract()) {
            stakingToken = StandardToken(GEN_TOKEN_ADDRESS);
        } else {
            stakingToken = _stakingToken;
        }
    }

  /**
   * @dev Check that the proposal is votable
   * a proposal is votable if it is in one of the following states:
   *  PreBoosted,Boosted,QuietEndingPeriod or Queued
   */
    modifier votable(bytes32 _proposalId) {
        require(_isVotable(_proposalId));
        _;
    }

    /**
     * @dev register a new proposal with the given parameters. Every proposal has a unique ID which is being
     * generated by calculating keccak256 of a incremented counter.
     * @param _paramsHash parameters hash
     * @param _proposer address
     * @param _organization address
     */
    function propose(uint , bytes32 _paramsHash,address _proposer,address _organization)
        external
        returns(bytes32)
    {
      // solium-disable-next-line security/no-block-members
        require(now > parameters[_paramsHash].activationTime,"not active yet");
        //Check parameters existence.
        require(parameters[_paramsHash].queuedVoteRequiredPercentage >= 50);
        // Generate a unique ID:
        bytes32 proposalId = keccak256(abi.encodePacked(this, proposalsCnt));
        proposalsCnt++;
         // Open proposal:
        Proposal memory proposal;
        proposal.callbacks = msg.sender;
        proposal.organizationId = keccak256(abi.encodePacked(msg.sender,_organization));

        proposal.state = ProposalState.Queued;
        // solium-disable-next-line security/no-block-members
        proposal.times[0] = now;//submitted time
        proposal.currentBoostedVotePeriodLimit = parameters[_paramsHash].boostedVotePeriodLimit;
        proposal.proposer = _proposer;
        proposal.winningVote = NO;
        proposal.paramsHash = _paramsHash;
        if (organizations[proposal.organizationId] == 0) {
            if (_organization == address(0)) {
                organizations[proposal.organizationId] = msg.sender;
            } else {
                organizations[proposal.organizationId] = _organization;
            }
        }
        //calc dao bounty
        uint daoBounty = parameters[_paramsHash].daoBountyConst.mul(averagesDownstakesOfBoosted[proposal.organizationId]);
        if (daoBounty < parameters[_paramsHash].minimumDaoBounty) {
            proposal.daoBountyRemain = parameters[_paramsHash].minimumDaoBounty;
        } else {
            proposal.daoBountyRemain = daoBounty;
        }
        proposal.totalStakes = proposal.daoBountyRemain;
        proposals[proposalId] = proposal;
        proposals[proposalId].stakes[NO] = proposal.daoBountyRemain;//dao downstake on the proposal
        Staker storage staker = proposals[proposalId].stakers[organizations[proposal.organizationId]];
        staker.vote = NO;
        staker.amount = proposal.daoBountyRemain;

        emit NewProposal(proposalId, organizations[proposal.organizationId], NUM_OF_CHOICES, _proposer, _paramsHash);
        return proposalId;
    }

    /**
      * @dev executeBoosted try to execute a boosted proposal if it is expired
      * @param _proposalId the id of the proposal
      * @return uint expirationCallBounty the bounty amount for the expiration call
     */
    function executeBoosted(bytes32 _proposalId) external returns(uint expirationCallBounty) {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.state == ProposalState.Boosted);
        require(_execute(_proposalId),"proposal need to expire");
        // solium-disable-next-line security/no-block-members
        uint expirationCallBountyPercentage = (1 + now.sub(proposal.currentBoostedVotePeriodLimit + proposal.times[1]).div(15));
        if (expirationCallBountyPercentage > 100) {
            expirationCallBountyPercentage = 100;
        }
        proposal.expirationCallBountyPercentage = expirationCallBountyPercentage;
        expirationCallBounty = expirationCallBountyPercentage.mul(proposal.stakes[YES]).div(100);
        require(stakingToken.transfer(msg.sender, expirationCallBounty),"transfer to msg.sender failed");
        emit ExpirationCallBounty(_proposalId,msg.sender,expirationCallBounty);
    }

    /**
     * @dev redeem a reward for a successful stake, vote or proposing.
     * The function use a beneficiary address as a parameter (and not msg.sender) to enable
     * users to redeem on behalf of someone else.
     * @param _proposalId the ID of the proposal
     * @param _beneficiary - the beneficiary address
     * @return rewards -
     *           [0] stakerTokenReward
     *           [1] voterReputationReward
     *           [2] proposerReputationReward
     */
    function redeem(bytes32 _proposalId,address _beneficiary) public returns (uint[3] rewards) {
        Proposal storage proposal = proposals[_proposalId];
        // solium-disable-next-line max-len
        require((proposal.state == ProposalState.Executed)||(proposal.state == ProposalState.ExpiredInQueue),"Proposal should be Executed or ExpiredInQueue");
        Parameters memory params = parameters[proposal.paramsHash];
        uint lostReputation;
        if (proposal.winningVote == YES) {
            lostReputation = proposal.preBoostedVotes[NO];
        } else {
            lostReputation = proposal.preBoostedVotes[YES];
        }
        lostReputation = (lostReputation * params.votersReputationLossRatio)/100;
        //as staker
        Staker storage staker = proposal.stakers[_beneficiary];
        if (staker.amount > 0) {
            if (proposal.state == ProposalState.ExpiredInQueue) {
                //Stakes of a proposal that expires in Queue are sent back to stakers
                rewards[0] = staker.amount;
          }else if (staker.vote == proposal.winningVote) {
                    uint totalWinningStakes = proposal.stakes[proposal.winningVote];
                    uint totalStakes = proposal.stakes[YES]+proposal.stakes[NO];
                    if (staker.vote == YES) {
                        uint _totalStakes = ((totalStakes*(100 - proposal.expirationCallBountyPercentage))/100) - proposal.daoBounty;
                        rewards[0] = (staker.amount*_totalStakes)/totalWinningStakes;
                    } else {
                        rewards[0] = (staker.amount*totalStakes)/totalWinningStakes;
                        if (organizations[proposal.organizationId] == _beneficiary) {
                          //dao redeem it reward
                            rewards[0] = rewards[0].sub(proposal.daoBounty);
                        }
                    }

          }
            staker.amount = 0;
        }
        //as voter
        Voter storage voter = proposal.voters[_beneficiary];
        if ((voter.reputation != 0 ) && (voter.preBoosted)) {
            uint preBoostedVotes = proposal.preBoostedVotes[YES] + proposal.preBoostedVotes[NO];
            if (proposal.state == ProposalState.ExpiredInQueue) {
              //give back reputation for the voter
                rewards[1] = ((voter.reputation * params.votersReputationLossRatio)/100);
            } else if (proposal.winningVote == voter.vote ) {
                rewards[1] = (((voter.reputation * params.votersReputationLossRatio)/100) +
                ((voter.reputation * lostReputation)/preBoostedVotes));
            }
            voter.reputation = 0;
        }
        //as proposer
        if ((proposal.proposer == _beneficiary)&&(proposal.winningVote == YES)&&(proposal.proposer != address(0))) {
            rewards[2] = params.proposingRepReward;
            proposal.proposer = 0;
        }
        if (rewards[0] != 0) {
            proposal.totalStakes = proposal.totalStakes.sub(rewards[0]);
            require(stakingToken.transfer(_beneficiary, rewards[0]));
            emit Redeem(_proposalId,organizations[proposal.organizationId],_beneficiary,rewards[0]);
        }
        if ((rewards[1] + rewards[2]) != 0 ) {
            VotingMachineCallbacksInterface(proposal.callbacks).mintReputation(rewards[1] + rewards[2],_beneficiary,_proposalId);
            emit RedeemReputation(_proposalId,organizations[proposal.organizationId],_beneficiary,rewards[1] + rewards[2]);
        }
    }

    /**
     * @dev redeemDaoBounty a reward for a successful stake.
     * The function use a beneficiary address as a parameter (and not msg.sender) to enable
     * users to redeem on behalf of someone else.
     * @param _proposalId the ID of the proposal
     * @param _beneficiary - the beneficiary address
     * @return redeemedAmount - redeem token amount
     * @return potentialAmount - potential redeem token amount(if there is enough tokens bounty at the organization )
     */
    function redeemDaoBounty(bytes32 _proposalId,address _beneficiary) public returns(uint redeemedAmount,uint potentialAmount) {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.state == ProposalState.Executed);
        uint totalWinningStakes = proposal.stakes[proposal.winningVote];
        Staker storage staker = proposal.stakers[_beneficiary];
        if (
          // solium-disable-next-line operator-whitespace
            (staker.amount4Bounty > 0)&&
            (staker.vote == proposal.winningVote)&&
            (proposal.winningVote == YES)&&
            (totalWinningStakes != 0))
        {
            //as staker
            potentialAmount = (staker.amount4Bounty * proposal.daoBounty)/totalWinningStakes;
        }
        if ((potentialAmount != 0)&&
            (VotingMachineCallbacksInterface(proposal.callbacks).balanceOfStakingToken(stakingToken,_proposalId) >= potentialAmount))
        {
            staker.amount4Bounty = 0;
            proposal.daoBountyRemain = proposal.daoBountyRemain.sub(potentialAmount);
            require(VotingMachineCallbacksInterface(proposal.callbacks).stakingTokenTransfer(stakingToken,_beneficiary,potentialAmount,_proposalId));
            redeemedAmount = potentialAmount;
            emit RedeemDaoBounty(_proposalId,organizations[proposal.organizationId],_beneficiary,redeemedAmount);
        }
    }

    /**
     * @dev shouldBoost check if a proposal should be shifted to boosted phase.
     * @param _proposalId the ID of the proposal
     * @return bool true or false.
     */
    function shouldBoost(bytes32 _proposalId) public view returns(bool) {
        Proposal memory proposal = proposals[_proposalId];
        return (_score(_proposalId) > threshold(proposal.paramsHash,proposal.organizationId));
    }

    /**
     * @dev threshold return the organization's score threshold which required by
     * a proposal to shift to boosted state.
     * This threshold is dynamically set and it depend on the number of boosted proposal.
     * @param _organizationId the organization identifier
     * @param _paramsHash the organization parameters hash
     * @return uint organization's score threshold.
     */
    function threshold(bytes32 _paramsHash,bytes32 _organizationId) public view returns(uint) {
        int256 power = int216(orgBoostedProposalsCnt[_organizationId]).toReal();
        Parameters storage params = parameters[_paramsHash];

        if (power.fromReal() > int(params.limitExponentValue) ) {
            power = int216(params.limitExponentValue).toReal();
        }

        return uint(params.thresholdConst.pow(power).fromReal());
    }

    /**
     * @dev hash the parameters, save them if necessary, and return the hash value
     * @param _params a parameters array
     *    _params[0] - _queuedVoteRequiredPercentage,
     *    _params[1] - _queuedVotePeriodLimit, //the time limit for a proposal to be in an absolute voting mode.
     *    _params[2] - _boostedVotePeriodLimit, //the time limit for a proposal to be in an relative voting mode.
     *    _params[3] - _preBoostedVotePeriodLimit, //the time limit for a proposal to be in an preparation state (stable) before boosted.
     *    _params[4] -_thresholdConst
     *    _params[5] -_quietEndingPeriod
     *    _params[6] -_proposingRepReward
     *    _params[7] -_votersReputationLossRatio
     *    _params[8] -_minimumDaoBounty
     *    _params[9] -_daoBountyConst
     *    _params[10] -_activationTime
     * @param _voteOnBehalf - authorized to vote on behalf of others.
    */
    function setParameters(
        uint[11] _params, //use array here due to stack too deep issue.
        address _voteOnBehalf
    )
    public
    returns(bytes32)
    {
        require(_params[0] <= 100 && _params[0] >= 50,"50 <= queuedVoteRequiredPercentage <= 100");
        require(_params[4] <= 16000 && _params[4] > 1000,"1000 < thresholdConst <= 16000");
        require(_params[7] <= 100,"votersReputationLossRatio <= 100");
        require(_params[2] >= _params[5],"boostedVotePeriodLimit >= quietEndingPeriod");
        require(_params[8] > 0,"minimumDaoBounty should be > 0");
        require(_params[9] > 0,"daoBountyConst should be > 0");

        bytes32 paramsHash = getParametersHash(_params, _voteOnBehalf);

        int alpha = int216(_params[4]).fraction(int216(1000));
        //set a limit for power for a given alpha to prevent overflow
        uint limitExponent = 172;//for alpha less or equal 2
        uint j = 2;
        for (uint i = 2;i < 16 ;i = i*2) {
            if ((uint(alpha.fromReal()) > i) && (uint(alpha.fromReal()) <= i*2)) {
                limitExponent = limitExponent/j;
                break;
             }
            j++;
        }

        parameters[paramsHash] = Parameters({
            queuedVoteRequiredPercentage: _params[0],
            queuedVotePeriodLimit: _params[1],
            boostedVotePeriodLimit: _params[2],
            preBoostedVotePeriodLimit: _params[3],
            thresholdConst:alpha,
            limitExponentValue:limitExponent,
            quietEndingPeriod: _params[5],
            proposingRepReward: _params[6],
            votersReputationLossRatio:_params[7],
            minimumDaoBounty:_params[8],
            daoBountyConst:_params[9],
            activationTime:_params[10],
            voteOnBehalf:_voteOnBehalf
        });
        return paramsHash;
    }

  /**
   * @dev hashParameters returns a hash of the given parameters
   */
    function getParametersHash(
        uint[11] _params,//use array here due to stack too deep issue.
        address _voteOnBehalf
    )
        public
        pure
        returns(bytes32)
        {
        //double call to keccak256 to avoid deep stack issue when call with too many params.
        return keccak256(
            abi.encodePacked(
             keccak256(
              abi.encodePacked(
                _params[0],
                _params[1],
                _params[2],
                _params[3],
                _params[4],
                _params[5],
                _params[6],
                _params[7],
                _params[8],
                _params[9],
                _params[10]
             )),
            _voteOnBehalf
        ));
    }

    /**
      * @dev execute check if the proposal has been decided, and if so, execute the proposal
      * @param _proposalId the id of the proposal
      * @return bool true - the proposal has been executed
      *              false - otherwise.
     */
    function _execute(bytes32 _proposalId) internal votable(_proposalId) returns(bool) {
        Proposal storage proposal = proposals[_proposalId];
        Parameters memory params = parameters[proposal.paramsHash];
        Proposal memory tmpProposal = proposal;
        uint totalReputation = VotingMachineCallbacksInterface(proposal.callbacks).getTotalReputationSupply(_proposalId);
        uint executionBar = totalReputation * params.queuedVoteRequiredPercentage/100;
        ExecutionState executionState = ExecutionState.None;
        uint averageDownstakesOfBoosted;
        uint confidenceThreshold;

        if (proposal.votes[proposal.winningVote] > executionBar) {
         // someone crossed the absolute vote execution bar.
            if (proposal.state == ProposalState.Queued) {
                executionState = ExecutionState.QueueBarCrossed;
            } else if (proposal.state == ProposalState.PreBoosted) {
                executionState = ExecutionState.PreBoostedBarCrossed;
            } else {
                executionState = ExecutionState.BoostedBarCrossed;
            }
            proposal.state = ProposalState.Executed;
         } else {
            if (proposal.state == ProposalState.Queued) {
                // solium-disable-next-line security/no-block-members
                if ((now - proposal.times[0]) >= params.queuedVotePeriodLimit) {
                    proposal.state = ProposalState.ExpiredInQueue;
                    proposal.winningVote = NO;
                    executionState = ExecutionState.QueueTimeOut;
                 } else {
                    confidenceThreshold = threshold(proposal.paramsHash,proposal.organizationId);
                    if (_score(_proposalId) > confidenceThreshold) {
                        //change proposal mode to PreBoosted mode.
                        proposal.state = ProposalState.PreBoosted;
                        // solium-disable-next-line security/no-block-members
                        proposal.times[2] = now;
                        proposal.confidenceThreshold = confidenceThreshold;
                   }
                }
               }

            if (proposal.state == ProposalState.PreBoosted) {
                confidenceThreshold = threshold(proposal.paramsHash,proposal.organizationId);
              // solium-disable-next-line security/no-block-members
                if ((now - proposal.times[2]) >= params.preBoostedVotePeriodLimit) {
                    if (_score(_proposalId) > confidenceThreshold) {
                       //change proposal mode to Boosted mode.
                        proposal.state = ProposalState.Boosted;
                       // solium-disable-next-line security/no-block-members
                        proposal.times[1] = now;
                        orgBoostedProposalsCnt[proposal.organizationId]++;
                       //add a value to average -> average = average + ((value - average) / nbValues)
                        averageDownstakesOfBoosted = averagesDownstakesOfBoosted[proposal.organizationId];
                        // solium-disable-next-line indentation
                        averagesDownstakesOfBoosted[proposal.organizationId] = uint256(int256(averageDownstakesOfBoosted) +
                            ((int216(proposal.stakes[NO])-int216(averageDownstakesOfBoosted))
                            .toReal().div(int216(orgBoostedProposalsCnt[proposal.organizationId]).toReal()))
                            .fromReal());
                 }
               } else { //check the Confidence level is stable
                    uint proposalScore = _score(_proposalId);
                    if (proposalScore <= proposal.confidenceThreshold.min256(confidenceThreshold)) {
                        proposal.state = ProposalState.Queued;
                    } else if (proposal.confidenceThreshold > proposalScore) {
                        proposal.confidenceThreshold = confidenceThreshold;
                    }
               }
            }
        }

        if ((proposal.state == ProposalState.Boosted) ||
            (proposal.state == ProposalState.QuietEndingPeriod)) {
            // solium-disable-next-line security/no-block-members
            if ((now - proposal.times[1]) >= proposal.currentBoostedVotePeriodLimit) {
                proposal.state = ProposalState.Executed;
                executionState = ExecutionState.BoostedTimeOut;
            }
          }

        if (executionState != ExecutionState.None) {
            if ((executionState == ExecutionState.BoostedTimeOut) || (executionState == ExecutionState.BoostedBarCrossed)) {
                orgBoostedProposalsCnt[tmpProposal.organizationId] = orgBoostedProposalsCnt[tmpProposal.organizationId].sub(1);
                //remove a value from average = ((average * nbValues) - value) / (nbValues - 1);
                uint boostedProposals = orgBoostedProposalsCnt[tmpProposal.organizationId];
                if (boostedProposals == 0) {
                    averagesDownstakesOfBoosted[proposal.organizationId] = 0;
                } else {
                    averageDownstakesOfBoosted = averagesDownstakesOfBoosted[proposal.organizationId];
                    averagesDownstakesOfBoosted[proposal.organizationId] = uint256(int216(averageDownstakesOfBoosted.mul(boostedProposals+1).sub(proposal.stakes[NO])).toReal().div(int216(boostedProposals).toReal()).fromReal());
                }
            }
            emit ExecuteProposal(_proposalId, organizations[proposal.organizationId], proposal.winningVote, totalReputation);
            emit GPExecuteProposal(_proposalId, executionState);
            ProposalExecuteInterface(proposal.callbacks).executeProposal(_proposalId,int(proposal.winningVote));
            proposal.daoBounty = proposal.daoBountyRemain;
        }
        return (executionState != ExecutionState.None);
    }

    /**
     * @dev staking function
     * @param _proposalId id of the proposal
     * @param _vote  NO(2) or YES(1).
     * @param _amount the betting amount
     * @return bool true - the proposal has been executed
     *              false - otherwise.
     */
    function _stake(bytes32 _proposalId, uint _vote, uint _amount,address _staker) internal returns(bool) {
        // 0 is not a valid vote.
        require(_vote <= NUM_OF_CHOICES && _vote > 0);
        require(_amount > 0);
        if (_execute(_proposalId)) {
            return true;
        }

        Proposal storage proposal = proposals[_proposalId];

        if ((proposal.state != ProposalState.PreBoosted) &&
           (proposal.state != ProposalState.Queued))
        {
            return false;
        }

        // enable to increase stake only on the previous stake vote
        Staker storage staker = proposal.stakers[_staker];
        if ((staker.amount > 0) && (staker.vote != _vote)) {
            return false;
        }

        uint amount = _amount;
        require(stakingToken.transferFrom(_staker, address(this), amount),"fail transfer from staker");
        proposal.totalStakes = proposal.totalStakes.add(amount); //update totalRedeemableStakes
        staker.amount += amount;
        if (_vote == YES) {
            staker.amount4Bounty += amount;
        }
        staker.vote = _vote;

        proposal.stakes[_vote] = amount.add(proposal.stakes[_vote]);
        emit Stake(_proposalId, organizations[proposal.organizationId], _staker, _vote, _amount);
        return _execute(_proposalId);
    }

    /**
     * @dev Vote for a proposal, if the voter already voted, cancel the last vote and set a new one instead
     * @param _proposalId id of the proposal
     * @param _voter used in case the vote is cast for someone else
     * @param _vote a value between 0 to and the proposal's number of choices.
     * @param _rep how many reputation the voter would like to stake for this vote.
     *         if  _rep==0 so the voter full reputation will be use.
     * @return true in case of proposal execution otherwise false
     * throws if proposal is not open or if it has been executed
     * NB: executes the proposal if a decision has been reached
     */
    function internalVote(bytes32 _proposalId, address _voter, uint _vote, uint _rep) internal returns(bool) {
        // 0 is not a valid vote.
        require(_vote <= NUM_OF_CHOICES && _vote > 0,"0 < _vote <= 2");
        if (_execute(_proposalId)) {
            return true;
        }

        Parameters memory params = parameters[proposals[_proposalId].paramsHash];
        Proposal storage proposal = proposals[_proposalId];

        // Check voter has enough reputation:
        uint reputation = VotingMachineCallbacksInterface(proposal.callbacks).reputationOf(_voter,_proposalId);
        require(reputation >= _rep,"reputation >= _rep");
        uint rep = _rep;
        if (rep == 0) {
            rep = reputation;
        }
        // If this voter has already voted, return false.
        if (proposal.voters[_voter].reputation != 0) {
            return false;
        }
        // The voting itself:
        proposal.votes[_vote] = rep.add(proposal.votes[_vote]);
        //check if the current winningVote changed or there is a tie.
        //for the case there is a tie the current winningVote set to NO.
        if ((proposal.votes[_vote] > proposal.votes[proposal.winningVote]) ||
           ((proposal.votes[NO] == proposal.votes[proposal.winningVote]) &&
             proposal.winningVote == YES))
        {
            // solium-disable-next-line security/no-block-members
            if (((proposal.state == ProposalState.Boosted) && ((now - proposal.times[1]) >= (params.boostedVotePeriodLimit - params.quietEndingPeriod))||
                 (proposal.state == ProposalState.QuietEndingPeriod))) {
                                 //quietEndingPeriod
                if (proposal.state != ProposalState.QuietEndingPeriod) {
                    proposal.currentBoostedVotePeriodLimit = params.quietEndingPeriod;
                    proposal.state = ProposalState.QuietEndingPeriod;
                }
                // solium-disable-next-line security/no-block-members
                proposal.times[1] = now;
            }
            proposal.winningVote = _vote;
        }
        proposal.voters[_voter] = Voter({
            reputation: rep,
            vote: _vote,
            preBoosted:((proposal.state == ProposalState.PreBoosted) || (proposal.state == ProposalState.Queued))
        });
        if ((proposal.state == ProposalState.PreBoosted) || (proposal.state == ProposalState.Queued)) {
            proposal.preBoostedVotes[_vote] = rep.add(proposal.preBoostedVotes[_vote]);
            uint reputationDeposit = (params.votersReputationLossRatio * rep)/100;
            VotingMachineCallbacksInterface(proposal.callbacks).burnReputation(reputationDeposit,_voter,_proposalId);
        }
        // Event:
        emit VoteProposal(_proposalId, organizations[proposal.organizationId], _voter, _vote, rep);
        // execute the proposal if this vote was decisive:
        return _execute(_proposalId);
    }

    /**
     * @dev _score return the proposal score (Confidence level)
     * For dual choice proposal S = (S+)/(S-)
     * @param _proposalId the ID of the proposal
     * @return uint proposal score.
     */
    function _score(bytes32 _proposalId) internal view returns(uint) {
        Proposal storage proposal = proposals[_proposalId];
        if (proposal.stakes[NO] == 0) {
            return 0;
        }
        return uint((int216(proposal.stakes[YES]).toReal().div(int216(proposal.stakes[NO]).toReal())).fromReal());
    }

    /**
      * @dev _isVotable check if the proposal is votable
      * @param _proposalId the ID of the proposal
      * @return bool true or false
    */
    function _isVotable(bytes32 _proposalId) internal view returns(bool) {
        ProposalState pState = proposals[_proposalId].state;
        // solium-disable-next-line operator-whitespace
        return ((pState == ProposalState.PreBoosted)||
                (pState == ProposalState.Boosted)||
                (pState == ProposalState.QuietEndingPeriod)||
                (pState == ProposalState.Queued)
        );
    }
}
