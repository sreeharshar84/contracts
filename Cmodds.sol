// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;
import "@chainlink/contracts/src/v0.8/dev/ChainlinkClient.sol";

interface BetNFT {
    function mint(address _to, uint256 _tokenId, string calldata matchId, uint256 _betId, string calldata ipfsLocation) external;
    function getTokenURI(uint256 tokenId) external returns (string memory) ;
    function getBetDetails(uint256 tokenId) external returns (string memory, uint256);
    function redeemCollectible(uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract Cmodds is ChainlinkClient {
    using Chainlink for Chainlink.Request;

    bytes32 public data;
    string public resultString;
    address private oracle;
    bytes32 private jobId;
    uint256 private fee;

    uint256 public betCount;

    // NFT Token Count tracker;
    uint256 public nftTokenCount;

    enum BetType {Back, Lay}
    enum Selection {Open, Home, Away, Draw}
    enum BetStatus {Unmatched, Matched, Closed, Win, Lose}
    enum GameStatus {Open, Complete}
      
    struct Game {
        address owner;
        string objectId;
        GameStatus status;
        Selection winner;
    }

    struct Bet {
        address addr;
        uint256 amount;
        uint256 odds;
        Selection selection;
        BetType betType;
        BetStatus status;

        // NFT Details
        bool shiftedToNFT;
        uint256 nftTokenId;

        // Player ID
        uint256 betId;
    }
 
    /// hold the game data
    Game game;
    /// hold all unmatched bets
    mapping(BetType => mapping(Selection => uint256[])) unmatchedBets;
    /// hold all back bets by matched index
    mapping(uint => uint256[]) backBets;
     /// hold all lay bets by matched index
    mapping(uint => uint256[]) layBets;
    /// matched index to connect lay and back bets
    uint matchedIndex;

    Bet[] allBets;

    /// track NFTs
    /*
     TODO: Lot of duplication of Bet objects.
     A different mapping with betId as key will be easier to use.
    */
    mapping(uint256 => uint256) betsConvertedToNFT;

    BetNFT public nftBet;

    /// Unmatched bet has been placed.
    event UnmatchedBetPlaced(string eventId, address addr, uint256 amount, uint256 odds, Selection selection, BetType betType);
    /// Matched bet has been placed.
    event MatchedBetPlaced(string eventId, address addr, uint256 amount, uint256 odds, Selection selection, BetType betType);
    /// Unmatched bet has been removed.
    event UnmatchedBetRemoved(string eventId, address addr, uint256 amount, uint256 odds, Selection selection, BetType betType);
    /// createBetObject
    event BetObjectCreated(address _addr, uint256 _amount, uint256 _odds, Selection _selection, BetType _betType, uint betId);

    
    /// Game has already ended.
    error GameAlreadyEnded();
    /// Bet Amount of `amount` to low.
    error AmountToLow(uint amount);
    /// Odds of `odds` to low.
    error OddsToLow(uint256 odds);
    /// Only Owner can call.
    error OnlyOwner();
    
    
    /// check if amount is greater then zero
    modifier amountGreaterZero(uint _amount) {
        if(_amount <= 0) revert AmountToLow(_amount);
        _;
    }
    
    /// check if valid odds
    modifier checkOdds(uint256 _odds) {
        if(_odds <= 1 ) revert OddsToLow(_odds);
        _;
    }
    
    /// check if valid odds
    modifier checkGameRunning() {
        if(game.status == GameStatus.Complete) revert GameAlreadyEnded();
        _;
    }
    
    /// check if address is from game owner
    modifier onlyOwner(address _addr) {
        if(_addr != game.owner) revert OnlyOwner();
        _;
    }
    

    /// Create game struct and init vars
    constructor(string memory _objectId) {
        game.owner = msg.sender;
        game.objectId = _objectId;
        game.status = GameStatus.Open;
        game.winner = Selection.Open;
        matchedIndex = 0;

        // Chainlink related functions
        setChainlinkToken(0x326C977E6efc84E512bB9C30f76E30c160eD06FB);
        oracle = 0xc8D925525CA8759812d0c299B90247917d4d4b7C;
        jobId = "7ecb74753e414b54b26ed1b911b88d67";
        fee = 10 ** 16;

        betCount = 0;

        // Use an already deployed contract on Mumbai
        nftBet = BetNFT(0xb4De4d37e5766bC3e314f3eDa244b1D0C097363C);
    }
    
    /// Set winner selection side and trigger payout
    function setWinner (Selection _winner) public onlyOwner(msg.sender) checkGameRunning() {
        game.winner = _winner;
        payout();
        game.status = GameStatus.Complete;
    }

    /// Public function for placing back bet -> msg.value = bet amount
    function createBackBet(uint256 _odds, uint256 _amount, Selection _selection) public payable checkGameRunning() amountGreaterZero(msg.value) checkOdds(_odds) {
        require(_amount == msg.value, "Amount and send value are not equal!");
        placeBet(msg.sender, _amount, _odds, _selection, BetType.Back);
    }

    /// Public function for placing lay bet -> msg.value = bet liqidity
    function createLayBet(uint256 _odds, uint256 _amount, Selection _selection) public payable checkGameRunning() amountGreaterZero(msg.value) checkOdds(_odds) {
        uint256 liqidity = (_amount * (_odds - 1 ether) / 1 ether);
        require(liqidity == msg.value, "Liqidity and send value are not equal!");
        placeBet(msg.sender, _amount, _odds, _selection, BetType.Lay);
    }

    function createBetObject(address _addr, uint256 _amount, uint256 _odds, Selection _selection, BetType _betType) internal returns (Bet memory b){
         b = Bet(_addr, _amount, _odds, _selection, _betType, BetStatus.Unmatched, false, 0, betCount);
         emit BetObjectCreated(_addr, _amount, _odds, _selection, _betType, betCount);
         betCount++;
    }
    
    /// Internal function for placing and matching all bets
    function placeBet(address _addr, uint256 _amount, uint256 _odds, Selection _selection, BetType _betType) internal {
          
        // Get opposite bet type
        BetType oppositeType = (BetType.Back == _betType) ? BetType.Lay: BetType.Back;
        
        // Get all unmatched bets from the same selection and the opposite bet type
        uint256[] memory unmatchedBetsArray = unmatchedBets[oppositeType][_selection];
        
        if(unmatchedBetsArray.length > 0){
            bool canMatch = false;
            uint256 amountLeft = _amount;
            
            // check if an unmatched bet can be matched with this _ bet
            for (uint i=0; i < unmatchedBetsArray.length; i++) {
                
                if(allBets[unmatchedBetsArray[i]].odds == _odds){
                    
                    // match 1 to 1 if amount is same
                    if(allBets[unmatchedBetsArray[i]].amount == amountLeft) {
                        canMatch = true;
                        uint256 matchingWith = unmatchedBetsArray[i];
                        Bet memory myBet = createBetObject(_addr, amountLeft,
                                                            _odds, _selection, _betType);
                        allBets.push(myBet);

                        // push back and lay bets to mapping
                        if(BetType.Back == _betType) {
                            backBets[matchedIndex].push(myBet.betId);
                            layBets[matchedIndex].push(matchingWith);
                        } else if (BetType.Lay == _betType) {
                            backBets[matchedIndex].push(matchingWith);
                            layBets[matchedIndex].push(myBet.betId);
                        }
                        
                        emit MatchedBetPlaced(game.objectId, myBet.addr,
                                              myBet.amount, myBet.odds,
                                              myBet.selection, myBet.betType);
                        emit MatchedBetPlaced(game.objectId,
                                               allBets[matchingWith].addr,
                                               allBets[matchingWith].amount,
                                               allBets[matchingWith].odds,
                                               allBets[matchingWith].selection,
                                               allBets[matchingWith].betType);
                        
                        // delete matching bet from unmatchedBets
                        delete unmatchedBets[oppositeType][_selection][i];
                        
                        // increment matched index
                        matchedIndex++;
                        amountLeft = 0;
                    } 
                     // match 1 to 1 if unmatched amount is higher
                    else if (allBets[unmatchedBetsArray[i]].amount > amountLeft) {
                        canMatch = true;
                        uint256 matchingWith = unmatchedBetsArray[i];
                        Bet memory myBet = createBetObject(_addr, amountLeft,
                                                           _odds, _selection, _betType);

                        allBets[matchingWith].amount = allBets[matchingWith].amount - amountLeft;
                        
                        // push back and lay bets to mapping
                        if(BetType.Back == _betType) {
                            backBets[matchedIndex].push(myBet.betId);
                            layBets[matchedIndex].push(matchingWith);
                        } else if (BetType.Lay == _betType) {
                            backBets[matchedIndex].push(matchingWith);
                            layBets[matchedIndex].push(myBet.betId);
                        }
                        
                        emit MatchedBetPlaced(game.objectId, myBet.addr,
                                              myBet.amount, myBet.odds,
                                              myBet.selection, myBet.betType);
                        emit MatchedBetPlaced(game.objectId,
                                              allBets[matchingWith].addr,
                                              allBets[matchingWith].amount,
                                              allBets[matchingWith].odds,
                                              allBets[matchingWith].selection,
                                              allBets[matchingWith].betType);
                        
                        // increment matched index
                        matchedIndex++;
                        amountLeft = 0;
                    }
              
                    // break if bet is matched
                    if(amountLeft == 0){
                        break;
                    }
                    
                }
            }
            
            if(!canMatch) {
                placeUnmatchedBet(_addr, _amount ,_odds, _selection, _betType);
            }
        } else {
             // if nothing to match, place unmatched bet
            placeUnmatchedBet(_addr, _amount, _odds, _selection, _betType);
        }
    }
  
    /// Internal function for placing unmatched bet
    function placeUnmatchedBet(address _addr, uint256 _amount, uint256 _odds, Selection _selection, BetType _betType) internal {
        Bet memory _bet = createBetObject(_addr, _amount, _odds, _selection, _betType);
        allBets.push(_bet);
        unmatchedBets[_betType][_selection].push(_bet.betId);
        emit UnmatchedBetPlaced(game.objectId, _addr, _amount, _odds, _selection, _betType);
    }
  
    /// Public function for removing unmatched bet
    function removeUnmatchedBet(uint256 _odds, uint256 _amount, Selection _selection, BetType _betType) public returns (bool) {

        // Get all unmatched bets with this _ type and selection
        if(unmatchedBets[_betType][_selection].length > 0){
            for (uint i=0; i < unmatchedBets[_betType][_selection].length; i++) {

                Bet memory _bet = allBets[unmatchedBets[_betType][_selection][i]];
                // skip if address is not from sender
                if(_bet.addr != msg.sender){
                    continue;
                }

                // check if this _ bet exits in contract, emit event, send amount back and remove from contract
                if(_bet.amount == _amount && _bet.odds == _odds  &&
                   _bet.odds == _odds && _bet.selection == _selection &&
                   _bet.betType == _betType && _bet.status == BetStatus.Unmatched) {

                    emit UnmatchedBetRemoved(game.objectId, msg.sender,
                                             _amount, _odds, _selection, _betType);

                    payable(msg.sender).transfer(_amount);
                    delete unmatchedBets[_betType][_selection][i];
                    return true;
                }
            }
        }
        return false;
    }

    function transferAmount(address addr, uint256 amount) internal {
       payable(addr).transfer(amount);
    }
  
    /// Internal function for paying all sides from all matched bets for the game
    function payout () internal {
        for (uint i=0; i < matchedIndex; i++) {
                
            // Get all matched back bets for current index
            for (uint y = 0; y < backBets[i].length ; y++) {
                // Check if back bet has won and send money
                if(allBets[backBets[i][y]].selection == game.winner &&
                   !allBets[backBets[i][y]].shiftedToNFT) {
                    uint256 amount = (allBets[backBets[i][y]].amount *
                                      (allBets[backBets[i][y]].odds - 1 )  / 1  );
                    transferAmount(allBets[backBets[i][y]].addr, amount);
                    allBets[backBets[i][y]].status = BetStatus.Win;
                }
            }
            
            // Get all matched lay bets for current index
            for (uint y = 0; y < layBets[i].length; y++) {
                // Check if lay bet has won and send money
                if(allBets[layBets[i][y]].selection != game.winner &&
                   !allBets[layBets[i][y]].shiftedToNFT) {
                    uint256 amount = (allBets[layBets[i][y]].amount *
                                      (allBets[layBets[i][y]].odds - 1 )  / 1  );
                    transferAmount(allBets[layBets[i][y]].addr, amount);
                    allBets[layBets[i][y]].status = BetStatus.Win;
                }
            }
        }
    }

    /**
     * Create a Chainlink request to retrieve API response, find the target
     * data, the result is a string in the format "fixtureId_Winner"
    */
    function requestResult() public returns (bytes32 requestId)
    {
        Chainlink.Request memory req =
         buildChainlinkRequest(jobId, address(this), this.fulfill.selector);

        req.add("fixtureId", game.objectId);

        // Sends the request
        return sendChainlinkRequestTo(oracle, req, fee);
    }

    /*
      Sample answers:
      Match Id -> 710580 (supplied through requestData) -> Manchester City vs Arsenal
      Bytes32 reply from Chainlink Node -> 0x3731303538303100000000000000000000000000000000000000000000000000
      Conversion to string / uint256 (by calling bytes32ToString)-> 7105801
      Match Id is appended with  0 - pending, 1 - Home win, 2 - Away win, 3 - Draw
      City won this match, hence match id is appended with 1.
    */
    function fulfill(bytes32 _requestId, bytes32 _data) public recordChainlinkFulfillment(_requestId) {
        data = _data;
        (resultString, game.winner) = bytes32ToString(data);
        if (game.winner != Selection.Open) {
            payout();
            game.status = GameStatus.Complete;
        }
    }

    function bytes32ToString(bytes32 _bytes32) public pure returns (string memory, Selection) {
        uint8 i = 0;
        uint8 c = 0;
        uint256 k = 0;
        while(i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 32 && _bytes32[i] != 0; i++) {
            bytesArray[i] = _bytes32[i];
            c = (uint8(_bytes32[i]) - 48);
            k = k * 10 + c;
        }
        //last digit inidicates the result of the match with this matchId.
        return (string(bytesArray), Selection(k % 10));
    }

    function stringToUint(string memory s) public pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 result = 0;
        for (uint i = 0; i < b.length; i++) { // c = b[i] was not needed
            uint c = uint(uint8(b[i]));
            if (c >= 48 && c <= 57) {
               result = result * 10 + (c - 48); // bytes and int are not compatible with the operator -.
            }
        }
        return result;
    }

    function getGameDetails() public view returns (string memory, Selection, GameStatus) {
        return (game.objectId, game.winner, game.status);
    }

    //NFT Section
    function transferBetToNFT (uint256 _betId,
                               string memory tokenURI) public returns (uint256) {

        if (_betId < betCount &&
            (allBets[_betId].status == BetStatus.Unmatched ||
             allBets[_betId].status == BetStatus.Matched)) {

            nftTokenCount = stringToUint(game.objectId) * 10 + _betId;
            nftBet.mint(msg.sender, nftTokenCount, game.objectId, _betId, tokenURI);

            // Shift the ownership of Player object.
            allBets[_betId].addr = address(0);
            allBets[_betId].shiftedToNFT = true;
            allBets[_betId].nftTokenId = nftTokenCount;
            betsConvertedToNFT[nftTokenCount] = _betId;
        }
        return nftTokenCount;
    }

    function withdrawWithNFT(uint256 tokenId) public payable {
        nftBet.redeemCollectible(tokenId);
        uint256 _betId = betsConvertedToNFT[tokenId];

        //TODO: How do I know if this token actually won?
        uint256 amount =(allBets[_betId].amount * (allBets[_betId].odds - 1 )  / 1  );
        transferAmount(msg.sender, amount);
        allBets[_betId].status = BetStatus.Closed;
    }

    /*
    function getBackBet(uint _matched, uint idx) public view returns (Bet memory) {
              return allBets[backBets[_matched][idx]];
    }
    function getLayBet(uint _matched, uint idx)  public view returns (Bet memory) {
              return allBets[layBets[_matched][idx]];
    }
    */
}
