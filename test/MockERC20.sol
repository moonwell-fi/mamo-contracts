import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// Mock ERC20 Token

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
