// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

interface IInterestData {
    function fetchCurrentRateIndex(
        address token
    ) external view returns (uint256);
}

contract DataHub is Ownable {
    struct UserData {
        mapping(address => uint256) asset_info; // tracks their portfolio (margined, and depositted)
        mapping(address => uint256) liability_info; // tracks what they owe per token * price
        mapping(address => mapping(address => uint256)) maintenance_margin_requirement; // tracks the MMR per token the user has in liabilities
        mapping(address => mapping(address => uint256)) initial_margin_requirement;
        mapping(address => uint256) pending_balances;
        mapping(address => uint256) interestRateIndex;
        mapping(address => uint256) earningRateIndex;
        bool margined; // if user has open margin positions this is true
        address[] tokens; // these are the tokens that comprise their portfolio ( assets, and liabilites, margined funds)
    }

    struct AssetData {
        bool initialized;
        uint256[2] tradeFees; // first in the array is taker fee, next is maker fee
        uint256 collateralMultiplier;
        uint256 initialMarginFee; // assigned in function Ex
        uint256 assetPrice;
        uint256 liquidationFee;
        uint256 initialMarginRequirement; // not for potantial removal - unnessecary
        uint256 MaintenanceMarginRequirement;
        uint256 totalAssetSupply;
        uint256 totalBorrowedAmount;
        uint256 optimalBorrowProportion; // need to brainsotrm on how to set this information
        uint256 maximumBorrowProportion; // we need an on the fly function for the current maximum borrowable AMOUNT  -- cant borrow the max available supply
        uint256 totalDepositors;
    }

    modifier checkRoleAuthority() {
        require(admins[msg.sender] == true, "Unauthorized");
        _;
    }

    constructor(
        address initialOwner,
        address _executor,
        address _deposit_vault,
        address _oracle,
        address _interest,
        address utils
    ) Ownable(initialOwner) {
        admins[_executor] = true;
        admins[_deposit_vault] = true;
        admins[_oracle] = true;
        admins[_interest] = true;
        admins[initialOwner] = true;
        admins[utils] = true;
        interestContract = IInterestData(_interest);
    }

    IInterestData public interestContract;

    function alterAdminRoles(
        address _deposit_vault,
        address _executor,
        address _oracle,
        address _interest,
        address _utils
    ) public onlyOwner {
        admins[_executor] = true;
        admins[_deposit_vault] = true;
        admins[_oracle] = true;
        admins[_interest] = true;
        admins[_utils] = true;
        interestContract = IInterestData(_interest);
    }

    /// @notice Keeps track of a users data
    /// @dev Go to IDatahub for more details
    mapping(address => UserData) public userdata;

    /// @notice Keeps track of an assets data
    /// @dev Go to IDatahub for more details
    mapping(address => AssetData) public assetdata;

    /// @notice Keeps track of contract admins
    mapping(address => bool) public admins;

    /// @notice Alters the users interest rate index (or epoch)
    /// @dev This is to change the users rate epoch, it would be changed after they pay interest.
    /// @param user the users address
    /// @param token the token being targetted
    function alterUsersInterestRateIndex(
        address user,
        address token
    ) external checkRoleAuthority {
        userdata[user].interestRateIndex[token] = interestContract
            .fetchCurrentRateIndex(token); // updates to be the current rate index..... 1+
    }

    function alterUsersEarningRateIndex(
        address user,
        address token
    ) external checkRoleAuthority {
        console.log("alterUserEarningRateIndex function");
        console.log(
            "current rate index",
            interestContract.fetchCurrentRateIndex(token)
        );
        userdata[user].earningRateIndex[token] = interestContract
            .fetchCurrentRateIndex(token);
    }

    function viewUsersEarningRateIndex(
        address user,
        address token
    ) public view returns (uint256) {
        return userdata[user].earningRateIndex[token];
    }

    /// @notice provides to the caller the users current rate epoch
    /// @dev This is to keep track of the last epoch the user paid at
    /// @param user the users address
    /// @param token the token being targetted
    function viewUsersInterestRateIndex(
        address user,
        address token
    ) public view returns (uint256) {
        return userdata[user].interestRateIndex[token];
    }

    /// -----------------------------------------------------------------------
    /// Assets
    /// -----------------------------------------------------------------------

    /// @notice This adds to the users assets
    /// @dev this function is to add to the users assets of a token
    /// @param user the users address
    /// @param token the token being targetted
    /// @param amount the amount to be added to their balance
    function addAssets(
        address user,
        address token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].asset_info[token] += amount;
    }

    /// @notice This removes balance from the users assets
    /// @dev this function is to remove assets from the users assets of a token
    /// @param user the users address
    /// @param token the token being targetted
    /// @param amount the amount to be removed to their balance
    function removeAssets(
        address user,
        address token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].asset_info[token] -= amount;
    }

    function changeTotalBorrowedAmountOfAsset(
        address token,
        uint256 _updated_value
    ) external checkRoleAuthority {
        assetdata[token].totalBorrowedAmount = _updated_value;
    }

    /// -----------------------------------------------------------------------
    /// Liabilities
    /// -----------------------------------------------------------------------

    /// @notice Alters a users liabilities
    /// @param user being targetted
    /// @param token being targetted
    /// @param amount to alter liabilities by
    function alterLiabilities(
        address user,
        address token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].liability_info[token] *= amount / (10 ** 18);
    }

    /// @notice Adds to a users liabilities
    /// @param user being targetted
    /// @param token being targetted
    /// @param amount to alter liabilities by
    function addLiabilities(
        address user,
        address token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].liability_info[token] += amount;
    }

    /// @notice removes a users liabilities
    /// @param user being targetted
    /// @param token being targetted
    /// @param amount to alter liabilities by
    function removeLiabilities(
        address user,
        address token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].liability_info[token] -= amount;
    }

    /// -----------------------------------------------------------------------
    /// Pending Balances --> when a trade is being executed the balance of the trade is moved to pending
    /// -----------------------------------------------------------------------

    /// @notice This adds a pending balance for the user on a token they are trading
    /// @dev We do this because when the oracle is called there is a gap in time where the user should not have assets because the trade is not finalized
    /// @param user being targetted
    /// @param token being targetted
    /// @param amount to add to pending balances
    function addPendingBalances(
        address user,
        address token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].pending_balances[token] += amount;
    }

    /// @notice This removes a pending balance for the user on a token they are trading
    /// @dev We do this when the trade is cleared by the oracle and the trade is executed.
    /// @param user being targetted
    /// @param token being targetted
    /// @param amount to remove from pending balances
    function removePendingBalances(
        address user,
        address token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].pending_balances[token] -= amount;
    }

    function alterMMR(
        address user,
        address in_token,
        address out_token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].maintenance_margin_requirement[in_token][out_token] *=
            amount /
            (10 ** 18);
    }

    function addMaintenanceMarginRequirement(
        address user,
        address in_token,
        address out_token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].maintenance_margin_requirement[in_token][
            out_token
        ] += amount;
    }

    function removeMaintenanceMarginRequirement(
        address user,
        address in_token,
        address out_token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].maintenance_margin_requirement[in_token][
            out_token
        ] -= amount;
    }

    function returnPairMMROfUser(
        address user,
        address in_token,
        address out_token
    ) public view returns (uint256) {
        return
            userdata[user].maintenance_margin_requirement[in_token][out_token];
    }

    function returnPairIMROfUser(
        address user,
        address in_token,
        address out_token
    ) public view returns (uint256) {
        return userdata[user].initial_margin_requirement[in_token][out_token];
    }

    function alterIMR(
        address user,
        address in_token,
        address out_token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].initial_margin_requirement[in_token][out_token] *=
            amount /
            (10 ** 18);
    }

    function addInitialMarginRequirement(
        address user,
        address in_token,
        address out_token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].initial_margin_requirement[in_token][
            out_token
        ] += amount;
    }

    function removeInitialMarginRequirement(
        address user,
        address in_token,
        address out_token,
        uint256 amount
    ) external checkRoleAuthority {
        userdata[user].initial_margin_requirement[in_token][
            out_token
        ] -= amount;
    }

    /// -----------------------------------------------------------------------
    /// Margin modifiers.
    /// -----------------------------------------------------------------------

    /// @notice This sets the users margin status
    /// @dev if the user does a margined trade we want to record them on the contract as having margin already
    /// @param user user address being targetted
    /// @param onOrOff this determines whether they are being turned as having margin or not
    function SetMarginStatus(
        address user,
        bool onOrOff
    ) external checkRoleAuthority {
        userdata[user].margined = onOrOff;
    }

    /// @notice This checks the users margin status and if they should be in that status state, and changes it if they should not be
    /// @param user the user being targetted
    /// @param token the token being traded or targetted
    /// @param BalanceToLeave the balance leaving their account
    function checkMarginStatus(
        address user,
        address token,
        uint256 BalanceToLeave
    ) external checkRoleAuthority {
        uint256 AssetBalance = userdata[user].asset_info[token];
        //  - userdata[user].pending_balances[token];
        if (userdata[user].margined == false) {
            if (AssetBalance < BalanceToLeave) {
                userdata[user].margined = true;
            }
            return;
        }
        return;
    }

    /// @notice This changes the users margin status
    /// @dev if they don't have any margined positions this should turn them into a "spot" user
    /// @param user the user being targetted
    function changeMarginStatus(
        address user
    ) external checkRoleAuthority returns (bool) {
        bool isMargined = false;
        for (uint256 j = 0; j < userdata[user].tokens.length; j++) {
            if (userdata[user].liability_info[userdata[user].tokens[j]] > 0) {
                // Token found in the array
                isMargined = true;
                break;
            }
        }

        userdata[user].margined = isMargined;
        return isMargined;
    }

    /// -----------------------------------------------------------------------
    /// Portfolio make-up  --> when a user has assets they are added to an array these function return or change that array
    /// -----------------------------------------------------------------------

    /// @notice This function removes an asset from a users portfolio
    /// @dev it removes a token address from their tokens[] array in user data so it doesnt touch their assets this is called after they have no assets or liabiltiies of the token
    /// @param user the user being targetted
    /// @param tokenToRemove the token to remove from the portfolio
    function removeAssetToken(
        address user,
        address tokenToRemove
    ) external checkRoleAuthority {
        UserData storage userData = userdata[user];

        for (uint256 i = 0; i < userData.tokens.length; i++) {
            address token = userData.tokens[i];
            if (token == tokenToRemove) {
                userData.tokens[i] = userData.tokens[
                    userData.tokens.length - 1
                ];
                userData.tokens.pop();
                break; // Exit the loop once the token is found and removed
            }
        }
    }

    /// @notice This function returns the users tokens array ( the tokens in their portfolio)
    /// @param user the user being targetted
    function returnUsersAssetTokens(
        address user
    ) external view returns (address[] memory) {
        return userdata[user].tokens;
    }

    /// @notice This function rchecks if a token is present in a users potrfolio
    /// @param users the users being targetted
    /// @param token being targetted
    function checkIfAssetIsPresent(
        address[] memory users,
        address token
    ) external checkRoleAuthority returns (bool) {
        bool tokenFound = false;

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];

            for (uint256 j = 0; j < userdata[user].tokens.length; j++) {
                if (userdata[user].tokens[j] == token) {
                    // Token found in the array
                    tokenFound = true;
                    break; // Exit the inner loop as soon as the token is found
                }
            }

            if (!tokenFound) {
                // Token not found for the current user, add it to the array
                userdata[user].tokens.push(token);
            }
        }

        // Return true if the token is found for at least one user
        return tokenFound;
    }

    /// -----------------------------------------------------------------------
    /// Asset Pool functions  -->
    /// -----------------------------------------------------------------------

    /// @notice This increases or decreases the asset supply of a given tokens
    /// @param token the token being targetted
    /// @param amount the amount to add or remove
    /// @param pos_neg if its adding or removing asset supply
    function settotalAssetSupply(
        address token,
        uint256 amount,
        bool pos_neg
    ) external checkRoleAuthority {
        if (pos_neg == true) {
            assetdata[token].totalAssetSupply += amount;
        } else {
            assetdata[token].totalAssetSupply -= amount;
        }
    }

    /// @notice This increases or decreases the total borrowed amount of a given tokens
    /// @dev TODO: change to modifytotalborrowedamount --> set implies we are making a new value not modifying an existing value
    /// @param token the token being targetted
    /// @param amount the amount to add or remove
    /// @param pos_neg if its adding or removing from the borrowed amount
    function setTotalBorrowedAmount(
        address token,
        uint256 amount,
        bool pos_neg
    ) external checkRoleAuthority {
        if (pos_neg == true) {
            assetdata[token].totalBorrowedAmount += amount;
        } else {
            assetdata[token].totalBorrowedAmount -= amount;
        }
    }

    /// -----------------------------------------------------------------------
    /// Asset Data functions  -->
    /// -----------------------------------------------------------------------

    /// @notice This returns the asset data of a given asset see Idatahub for more details on what it returns
    /// @param token the token being targetted
    /// @return returns the assets data
    function returnAssetLogs(
        address token
    ) public view returns (AssetData memory) {
        return assetdata[token];
    }

    /// @notice This returns the asset data of a given asset see Idatahub for more details on what it returns
    /// @param token the token being targetted
    /// @param assetPrice the starting asset price of the token
    /// @param initialMarginFee the fee charged when they take out margin on the token
    /// @param liquidationFee the fee they pay when being liquidated
    /// @param initialMarginRequirement the amount they have to have in their portfolio to take out margin
    /// @param MaintenanceMarginRequirement the amount they need to hold in their account to sustain a margin position of the asset
    /// @param optimalBorrowProportion the optimal borrow proportion
    /// @param maximumBorrowProportion the maximum borrow proportion of the asset
    function InitTokenMarket(
        address token,
        uint256 assetPrice,
        uint256 collateralMultiplier,
        uint256[2] memory tradeFees,
        uint256 initialMarginFee,
        uint256 liquidationFee,
        uint256 initialMarginRequirement,
        uint256 MaintenanceMarginRequirement,
        uint256 optimalBorrowProportion,
        uint256 maximumBorrowProportion
    ) external onlyOwner {
        require(
            !assetdata[token].initialized,
            "token has to be not already initialized"
        );
        require(
            liquidationFee < MaintenanceMarginRequirement,
            "liq must be smaller than mmr"
        );
        require(
            tradeFees[0] >= tradeFees[1],
            "taker fee must be bigger than maker fee"
        );

        assetdata[token] = AssetData({
            collateralMultiplier: collateralMultiplier,
            tradeFees: tradeFees,
            initialMarginFee: initialMarginFee,
            assetPrice: assetPrice,
            liquidationFee: liquidationFee,
            initialMarginRequirement: initialMarginRequirement,
            MaintenanceMarginRequirement: MaintenanceMarginRequirement,
            totalAssetSupply: 0,
            totalBorrowedAmount: 0,
            optimalBorrowProportion: optimalBorrowProportion,
            maximumBorrowProportion: maximumBorrowProportion,
            totalDepositors: 0,
            initialized: true
        });
    }

    function tradeFee(
        address token,
        uint256 feeType
    ) public view returns (uint256) {
        return 1e18 - (assetdata[token].tradeFees[feeType]);
    }

    /// @notice Changes the assets price
    /// @param token the token being targetted
    /// @param value the new price
    function toggleAssetPrice(
        address token,
        uint256 value
    ) external checkRoleAuthority {
        assetdata[token].assetPrice = value;
    }

    /// -----------------------------------------------------------------------
    /// User Data functions -->
    /// -----------------------------------------------------------------------

    /// @notice Returns a users data
    /// @param user being targetted
    /// @param token the users data of the token being queried
    /// @return a tuple containing their info of the token

    function ReadUserData(
        address user,
        address token
    )
        external
        view
        returns (uint256, uint256, uint256, bool, address[] memory)
    {
        uint256 assets = userdata[user].asset_info[token]; // tracks their portfolio (margined, and depositted)
        uint256 liabilities = userdata[user].liability_info[token];
        uint256 pending = userdata[user].pending_balances[token];
        bool margined = userdata[user].margined;
        address[] memory tokens = userdata[user].tokens;
        return (assets, liabilities, pending, margined, tokens);
    }

    /// @notice calculates the total dollar value of the users assets
    /// @param user the address of the user we want to query
    /// @return sumOfAssets the cumulative value of all their assets
    function calculateTotalAssetValue(
        address user
    ) public view returns (uint256) {
        uint256 sumOfAssets;
        for (uint256 i = 0; i < userdata[user].tokens.length; i++) {
            address token = userdata[user].tokens[i];
            sumOfAssets +=
                (assetdata[token].assetPrice *
                    userdata[user].asset_info[token]) /
                10 ** 18; // want to get like a whole normal number so balance and price correction
        }
        return sumOfAssets;
    }

    /// @notice calculates the total dollar value of the users liabilities
    /// @param user the address of the user we want to query
    /// @return sumOfliabilities the cumulative value of all their liabilities
    function calculateLiabilitiesValue(
        address user
    ) public view returns (uint256) {
        uint256 sumOfliabilities;
        for (uint256 i = 0; i < userdata[user].tokens.length; i++) {
            address token = userdata[user].tokens[i];
            sumOfliabilities +=
                (assetdata[token].assetPrice *
                    userdata[user].liability_info[token]) /
                10 ** 18; // want to get like a whole normal number so balance and price correction
        }
        return sumOfliabilities;
    }

    /// @notice calculates the total dollar value of the users portfolio
    /// @param user the address of the user we want to query
    /// @return returns their assets - liabilities value in dollars
    function calculateTotalPortfolioValue(
        address user
    ) external view returns (uint256) {
        return calculateTotalAssetValue(user) - calculateLiabilitiesValue(user);
    }

    /// @notice calculates the total dollar value of the users Collateral
    /// @param user the address of the user we want to query
    /// @return returns their assets - liabilities value in dollars
    function calculatePendingCollateralValue(
        address user
    ) external view returns (uint256) {
        uint256 sumOfAssets;
        for (uint256 i = 0; i < userdata[user].tokens.length; i++) {
            address token = userdata[user].tokens[i];
            sumOfAssets +=
                (((assetdata[token].assetPrice *
                    userdata[user].pending_balances[token]) / 10 ** 18) *
                    assetdata[token].collateralMultiplier) /
                10 ** 18; // want to get like a whole normal number so balance and price correction
        }
        return sumOfAssets - calculateLiabilitiesValue(user);
    }

    /// @notice calculates the total dollar value of the users Collateral
    /// @param user the address of the user we want to query
    /// @return returns their assets - liabilities value in dollars
    function calculateCollateralValue(
        address user
    ) external view returns (uint256) {
        uint256 sumOfAssets;
        for (uint256 i = 0; i < userdata[user].tokens.length; i++) {
            address token = userdata[user].tokens[i];
            sumOfAssets +=
                (((assetdata[token].assetPrice *
                    userdata[user].asset_info[token]) / 10 ** 18) *
                    assetdata[token].collateralMultiplier) /
                10 ** 18; // want to get like a whole normal number so balance and price correction
        }
        return sumOfAssets - calculateLiabilitiesValue(user);
    }

    /// @notice calculates the total dollar value of the users Aggregate initial margin requirement
    /// @param user the address of the user we want to query
    /// @return returns their AMMR
    function calculateAIMRForUser(
        address user
    ) external view returns (uint256) {
        uint256 AIMR;
        for (uint256 i = 0; i < userdata[user].tokens.length; i++) {
            address token = userdata[user].tokens[i];
            uint256 liabilities = userdata[user].liability_info[token];
            if (liabilities > 0) {
                for (uint256 j = 0; j < userdata[user].tokens.length; j++) {
                    address token_2 = userdata[user].tokens[j];
                    if (
                        userdata[user].initial_margin_requirement[token][
                            token_2
                        ] > 0
                    ) {
                        AIMR +=
                            (assetdata[token].assetPrice *
                                userdata[user].initial_margin_requirement[
                                    token
                                ][token_2]) /
                            10 ** 18;
                    }
                }
            }
        }
        return AIMR;
    }

    /// @notice calculates the total dollar value of the users Aggregate maintenance margin requirement
    /// @param user the address of the user we want to query
    /// @return returns their AMMR
    function calculateAMMRForUser(
        address user
    ) external view returns (uint256) {
        uint256 AMMR;
        for (uint256 i = 0; i < userdata[user].tokens.length; i++) {
            address token = userdata[user].tokens[i];
            uint256 liabilities = userdata[user].liability_info[token];
            if (liabilities > 0) {
                for (uint256 j = 0; j < userdata[user].tokens.length; j++) {
                    address token_2 = userdata[user].tokens[j];
                    if (
                        userdata[user].maintenance_margin_requirement[token][
                            token_2
                        ] > 0
                    ) {
                        AMMR +=
                            (assetdata[token].assetPrice *
                                userdata[user].maintenance_margin_requirement[
                                    token
                                ][token_2]) /
                            10 ** 18;
                    }
                }
            }
        }
        return AMMR;
    }

    receive() external payable {}
}
