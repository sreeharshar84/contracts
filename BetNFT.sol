import '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

contract BetNFT is ERC721, Ownable {
    
    using Strings for uint256;

    struct BetDetails {
      string matchId;
      uint256 betId;
    }
    
    // Optional mapping for token URIs
    mapping (uint256 => string) private _tokenURIs;
    mapping (uint256 => BetDetails) private _betIds;

    constructor(string memory _name, string memory _symbol)
      ERC721(_name, _symbol)
    {}
    
    function _setTokenURI(uint256 tokenId, string memory ipfsLocation,
                          string memory _matchId, uint256 _betId) internal virtual {
      require(_exists(tokenId), "ERC721Metadata: URI set of nonexistent token");
      _tokenURIs[tokenId] = ipfsLocation;
      _betIds[tokenId] = BetDetails({matchId: _matchId, betId: _betId});
    }
    
    function tokenURI(uint256 tokenId)
     public view virtual override returns (string memory) {
      require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");
      return _tokenURIs[tokenId];
    }
    
    function getTokenURI(uint256 tokenId)
     external view returns (string memory) {
      return tokenURI(tokenId);
    }
    
    function getBetDetails(uint256 tokenId)
     external view returns (string memory matchId, uint256 betId) {
      require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");
      matchId = _betIds[tokenId].matchId;
      betId = _betIds[tokenId].betId;
    }

    function redeemCollectible(uint256 tokenId) external {
        require(_exists(tokenId), "ERC721: token doesn't exist");
        _burn(tokenId);
        delete _betIds[tokenId];
    }

    function mint(address _to, uint256 _tokenId, string calldata matchId,
                  uint256 _betId, string calldata ipfsLocation) external {
      // call to ERC721 mint function
      _mint(_to, _tokenId);

      // Wrap it with details we need
      _setTokenURI(_tokenId, ipfsLocation, matchId, _betId);
    }
  }