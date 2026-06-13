///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Controller} from "../src/Controller.sol";
import {Token} from "../src/Token.sol";
import {Kernel} from "../src/Kernel.sol";
import {Vault} from "../src/Vault.sol";
import {TeamLocker} from "../src/TeamLocker.sol";
import {ControllerFactory} from "../src/factories/ControllerFactory.sol";
import {CreationCodeStore} from "../src/factories/CreationCodeStore.sol";
import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {CREATE3} from "../src/libraries/CREATE3.sol";
import {Slots} from "../src/libraries/Slots.sol";
import {Test} from "forge-std/Test.sol";

contract ControllerFactoryTest is Test {
    uint256 internal constant EIP170_MAX_CODE_SIZE = 24_576;
    uint256 internal constant PRE_MINE_AMOUNT = 100_000 ether;
    uint256 internal constant TEAM_TOKEN_AMOUNT = 25_000 ether;
    uint256 internal constant MAX_SUPPLY = 10_000_000 ether;

    event Enten__ControllerCreated(
        address indexed deployer,
        address indexed admin,
        bytes32 indexed salt,
        address controller,
        address vault,
        address kernel,
        address token,
        address teamLocker
    );

    function testConstructorRejectsZeroProtocolCollector() public {
        IControllerFactory.CreationCodeStores memory codeStores = _codeStores();

        vm.expectRevert(IControllerFactory.ControllerFactory__ZeroAddress.selector);
        new ControllerFactory(address(0), codeStores);
    }

    function testConstructorRejectsInvalidCreationCodeStore() public {
        IControllerFactory.CreationCodeStores memory codeStores = _codeStores();
        codeStores.controller = codeStores.token;

        vm.expectRevert(IControllerFactory.ControllerFactory__InvalidCreationCodeStore.selector);
        new ControllerFactory(makeAddr("Protocol Collector"), codeStores);
    }

    function testConstructorStoresCanonicalCreationCodeStores() public {
        IControllerFactory.CreationCodeStores memory codeStores = _codeStores();
        address protocolCollector = makeAddr("Protocol Collector");
        ControllerFactory factory = new ControllerFactory(protocolCollector, codeStores);
        IControllerFactory factoryView = IControllerFactory(address(factory));

        assertEq(factoryView.PROTOCOL_COLLECTOR(), protocolCollector);
        assertEq(factoryView.CONTROLLER_CODE_STORE(), codeStores.controller);
        assertEq(factoryView.KERNEL_CODE_STORE(), codeStores.kernel);
        assertEq(factoryView.VAULT_CODE_STORE(), codeStores.vault);
        assertEq(factoryView.TOKEN_CODE_STORE(), codeStores.token);
        assertEq(factoryView.TEAM_LOCKER_CODE_STORE(), codeStores.teamLocker);
        assertEq(factoryView.totalControllers(), 0);
    }

    function testCreationCodeStoresContainCanonicalCreationCodeWithinRuntimeLimit() public {
        IControllerFactory.CreationCodeStores memory codeStores = _codeStores();

        assertEq(keccak256(codeStores.controller.code), keccak256(type(Controller).creationCode));
        assertEq(keccak256(codeStores.kernel.code), keccak256(type(Kernel).creationCode));
        assertEq(keccak256(codeStores.vault.code), keccak256(type(Vault).creationCode));
        assertEq(keccak256(codeStores.token.code), keccak256(type(Token).creationCode));
        assertEq(keccak256(codeStores.teamLocker.code), keccak256(type(TeamLocker).creationCode));

        assertLe(codeStores.controller.code.length, EIP170_MAX_CODE_SIZE);
        assertLe(codeStores.kernel.code.length, EIP170_MAX_CODE_SIZE);
        assertLe(codeStores.vault.code.length, EIP170_MAX_CODE_SIZE);
        assertLe(codeStores.token.code.length, EIP170_MAX_CODE_SIZE);
        assertLe(codeStores.teamLocker.code.length, EIP170_MAX_CODE_SIZE);
    }

    function testPredictDeploymentSeparatesDeployersSaltsAndLabels() public {
        ControllerFactory factory = _factory(makeAddr("Protocol Collector"));
        bytes32 salt = keccak256("enten launch");

        IControllerFactory.Deployment memory first = factory.predictDeployment(makeAddr("First Deployer"), salt);
        IControllerFactory.Deployment memory second = factory.predictDeployment(makeAddr("Second Deployer"), salt);
        IControllerFactory.Deployment memory third =
            factory.predictDeployment(makeAddr("First Deployer"), keccak256("other launch"));

        assertNotEq(first.controller, first.kernel);
        assertNotEq(first.controller, first.vault);
        assertNotEq(first.controller, first.token);
        assertNotEq(first.kernel, first.vault);
        assertNotEq(first.kernel, first.token);
        assertNotEq(first.vault, first.token);
        assertNotEq(first.teamLocker, first.controller);
        assertNotEq(first.teamLocker, first.kernel);
        assertNotEq(first.teamLocker, first.vault);
        assertNotEq(first.teamLocker, first.token);

        assertNotEq(first.controller, second.controller);
        assertNotEq(first.kernel, second.kernel);
        assertNotEq(first.vault, second.vault);
        assertNotEq(first.token, second.token);
        assertNotEq(first.teamLocker, second.teamLocker);

        assertNotEq(first.controller, third.controller);
        assertNotEq(first.kernel, third.kernel);
        assertNotEq(first.vault, third.vault);
        assertNotEq(first.token, third.token);
        assertNotEq(first.teamLocker, third.teamLocker);
    }

    function testLaunchControllerWithCreate3ImmutableDeployment() public {
        address protocolCollector = makeAddr("Protocol Collector");
        address admin = makeAddr("Admin");
        address deployer = makeAddr("Deployer");
        address preMineReceiver = makeAddr("Pre Mine Receiver");
        bytes32 salt = keccak256("first enten deployment");

        ControllerFactory factory = _factory(protocolCollector);
        IControllerFactory.Deployment memory predicted = factory.predictDeployment(deployer, salt);
        IControllerFactory.LaunchConfig memory config = _config(preMineReceiver, PRE_MINE_AMOUNT, MAX_SUPPLY);

        vm.expectEmit(true, true, true, true, address(factory));
        emit Enten__ControllerCreated(
            deployer,
            admin,
            salt,
            predicted.controller,
            predicted.vault,
            predicted.kernel,
            predicted.token,
            predicted.teamLocker
        );

        vm.prank(deployer);
        IControllerFactory.Deployment memory deployed = factory.launchController(admin, salt, config);

        assertEq(deployed.controller, predicted.controller);
        assertEq(deployed.kernel, predicted.kernel);
        assertEq(deployed.vault, predicted.vault);
        assertEq(deployed.token, predicted.token);
        assertEq(deployed.teamLocker, predicted.teamLocker);

        _assertDeploymentWiring(deployed, admin, protocolCollector, preMineReceiver);
        _assertFactoryRegistry(factory, deployed);
        _assertCanonicalRuntime(deployed, admin, protocolCollector, preMineReceiver);
    }

    function testLaunchControllerWithTeamLockerSplitsPremineAndLocksTeamTokens() public {
        address protocolCollector = makeAddr("Protocol Collector");
        address admin = makeAddr("Admin");
        address deployer = makeAddr("Deployer");
        address preMineReceiver = makeAddr("Pre Mine Receiver");
        bytes32 salt = keccak256("team locker enten deployment");

        ControllerFactory factory = _factory(protocolCollector);
        IControllerFactory.Deployment memory predicted = factory.predictDeployment(deployer, salt);
        IControllerFactory.LaunchConfig memory config =
            _config(preMineReceiver, PRE_MINE_AMOUNT, TEAM_TOKEN_AMOUNT, MAX_SUPPLY);

        vm.expectEmit(true, true, true, true, address(factory));
        emit Enten__ControllerCreated(
            deployer,
            admin,
            salt,
            predicted.controller,
            predicted.vault,
            predicted.kernel,
            predicted.token,
            predicted.teamLocker
        );

        vm.prank(deployer);
        IControllerFactory.Deployment memory deployed = factory.launchController(admin, salt, config);

        Token token = Token(deployed.token);
        Kernel kernel = Kernel(deployed.kernel);
        TeamLocker locker = TeamLocker(deployed.teamLocker);
        uint256 nonTeamAmount = PRE_MINE_AMOUNT - TEAM_TOKEN_AMOUNT;

        assertEq(deployed.teamLocker, predicted.teamLocker);
        assertGt(deployed.teamLocker.code.length, 0);
        assertEq(token.totalSupply(), PRE_MINE_AMOUNT);
        assertEq(token.balanceOf(preMineReceiver), nonTeamAmount);
        assertEq(token.balanceOf(deployed.teamLocker), TEAM_TOKEN_AMOUNT);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(uint256(kernel.viewData(Slots.TEAM_LOCKED_TOKENS_SLOT)), TEAM_TOKEN_AMOUNT);
        assertEq(locker.STARTING_LOCKED(), TEAM_TOKEN_AMOUNT);
        assertEq(locker.TOKEN(), deployed.token);
        assertEq(address(locker.KERNEL()), deployed.kernel);
        assertTrue(locker.hasRole(locker.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(locker.hasRole(locker.CLAIMER_ROLE(), admin));
    }

    function testLaunchControllerRejectsZeroAdmin() public {
        ControllerFactory factory = _factory(makeAddr("Protocol Collector"));

        vm.expectRevert(IControllerFactory.ControllerFactory__ZeroAddress.selector);
        factory.launchController(address(0), keccak256("salt"), _config(address(0), 0, MAX_SUPPLY));
    }

    function testLaunchControllerRejectsDuplicateDeployerSalt() public {
        address deployer = makeAddr("Deployer");
        bytes32 salt = keccak256("duplicate salt");
        ControllerFactory factory = _factory(makeAddr("Protocol Collector"));

        vm.prank(deployer);
        factory.launchController(makeAddr("Admin"), salt, _config(address(0), 0, MAX_SUPPLY));

        vm.prank(deployer);
        vm.expectRevert(CREATE3.CREATE3__ProxyDeploymentFailed.selector);
        factory.launchController(makeAddr("Second Admin"), salt, _config(address(0), 0, MAX_SUPPLY));

        assertEq(factory.totalControllers(), 1);
    }

    function testLaunchControllerInvalidTokenConfigRevertsAtomically() public {
        address deployer = makeAddr("Deployer");
        bytes32 salt = keccak256("bad token config");
        ControllerFactory factory = _factory(makeAddr("Protocol Collector"));
        IControllerFactory.Deployment memory predicted = factory.predictDeployment(deployer, salt);

        vm.prank(deployer);
        vm.expectRevert(CREATE3.CREATE3__DeploymentFailed.selector);
        factory.launchController(makeAddr("Admin"), salt, _config(address(0), 0, 0));

        assertEq(factory.totalControllers(), 0);
        assertEq(predicted.controller.code.length, 0);
        assertEq(predicted.kernel.code.length, 0);
        assertEq(predicted.vault.code.length, 0);
        assertEq(predicted.token.code.length, 0);
        assertEq(predicted.teamLocker.code.length, 0);
    }

    function testLaunchControllerRejectsInvalidPremineSplit() public {
        ControllerFactory factory = _factory(makeAddr("Protocol Collector"));

        vm.expectRevert(IControllerFactory.ControllerFactory__InvalidLaunchConfig.selector);
        factory.launchController(makeAddr("Admin"), keccak256("too much team"), _config(address(0), 1, 2, MAX_SUPPLY));

        vm.expectRevert(IControllerFactory.ControllerFactory__ZeroAddress.selector);
        factory.launchController(
            makeAddr("Admin"), keccak256("zero premine receiver"), _config(address(0), 2, 1, MAX_SUPPLY)
        );
    }

    function testLaunchControllerRecordsMultipleDeploymentsInOrder() public {
        address deployer = makeAddr("Deployer");
        address admin = makeAddr("Admin");
        ControllerFactory factory = _factory(makeAddr("Protocol Collector"));
        bytes32 firstSalt = keccak256("first salt");
        bytes32 secondSalt = keccak256("second salt");

        IControllerFactory.Deployment memory firstPrediction = factory.predictDeployment(deployer, firstSalt);
        IControllerFactory.Deployment memory secondPrediction = factory.predictDeployment(deployer, secondSalt);

        vm.startPrank(deployer);
        IControllerFactory.Deployment memory first =
            factory.launchController(admin, firstSalt, _config(address(0), 0, MAX_SUPPLY));
        IControllerFactory.Deployment memory second =
            factory.launchController(admin, secondSalt, _config(address(0), 0, MAX_SUPPLY));
        vm.stopPrank();

        assertEq(first.controller, firstPrediction.controller);
        assertEq(second.controller, secondPrediction.controller);
        assertEq(factory.totalControllers(), 2);
        assertEq(factory.controllers(0), first.controller);
        assertEq(factory.controllers(1), second.controller);
        assertEq(factory.controllersByIndex(0), first.controller);
        assertEq(factory.controllersByIndex(1), second.controller);
    }

    function _config(address preMineReceiver, uint256 preMineAmount, uint256 maxSupply)
        internal
        pure
        returns (IControllerFactory.LaunchConfig memory)
    {
        return _config(preMineReceiver, preMineAmount, 0, maxSupply);
    }

    function _config(address preMineReceiver, uint256 preMineAmount, uint256 teamTokenAmount, uint256 maxSupply)
        internal
        pure
        returns (IControllerFactory.LaunchConfig memory)
    {
        return IControllerFactory.LaunchConfig({
            tokenName: "Enten",
            tokenSymbol: "ENTEN",
            preMineAddress: preMineReceiver,
            preMineAmount: preMineAmount,
            teamTokenAmount: teamTokenAmount,
            maxSupply: maxSupply
        });
    }

    function _factory(address protocolCollector) internal returns (ControllerFactory) {
        return new ControllerFactory(protocolCollector, _codeStores());
    }

    function _codeStores() internal returns (IControllerFactory.CreationCodeStores memory) {
        return IControllerFactory.CreationCodeStores({
            controller: address(new CreationCodeStore(type(Controller).creationCode)),
            kernel: address(new CreationCodeStore(type(Kernel).creationCode)),
            vault: address(new CreationCodeStore(type(Vault).creationCode)),
            token: address(new CreationCodeStore(type(Token).creationCode)),
            teamLocker: address(new CreationCodeStore(type(TeamLocker).creationCode))
        });
    }

    function _assertDeploymentWiring(
        IControllerFactory.Deployment memory deployed,
        address admin,
        address protocolCollector,
        address preMineReceiver
    ) internal view {
        Controller controller = Controller(deployed.controller);
        Kernel kernel = Kernel(deployed.kernel);
        Vault vault = Vault(deployed.vault);
        Token token = Token(deployed.token);

        assertEq(address(controller.KERNEL()), deployed.kernel);
        assertEq(address(controller.VAULT()), deployed.vault);
        assertEq(address(controller.TOKEN()), deployed.token);
        assertEq(controller.PROTOCOL_COLLECTOR(), protocolCollector);
        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(controller.hasRole(controller.EXECUTOR_ROLE(), admin));
        assertTrue(controller.hasRole(controller.MINT_PERMISSION_ROLE(), admin));

        assertEq(kernel.CONTROLLER(), deployed.controller);
        assertEq(kernel.VAULT(), deployed.vault);
        assertEq(kernel.accountingWriter(), deployed.vault);
        assertEq(vault.CONTROLLER(), deployed.controller);
        assertEq(address(vault.KERNEL()), deployed.kernel);
        assertEq(token.CONTROLLER(), deployed.controller);
        assertEq(token.name(), "Enten");
        assertEq(token.symbol(), "ENTEN");
        assertEq(token.MAX_SUPPLY(), MAX_SUPPLY);
        assertEq(token.totalSupply(), PRE_MINE_AMOUNT);
        assertEq(token.balanceOf(preMineReceiver), PRE_MINE_AMOUNT);
        assertEq(token.balanceOf(address(deployed.teamLocker)), 0);
        assertEq(deployed.teamLocker.code.length, 0);
        assertEq(uint256(kernel.viewData(Slots.TEAM_LOCKED_TOKENS_SLOT)), 0);
    }

    function _assertFactoryRegistry(ControllerFactory factory, IControllerFactory.Deployment memory deployed)
        internal
        view
    {
        assertEq(factory.totalControllers(), 1);
        assertEq(factory.controllers(0), deployed.controller);
        assertEq(factory.controllersByIndex(0), deployed.controller);

        (
            address storedController,
            address storedKernel,
            address storedVault,
            address storedToken,
            address storedTeamLocker
        ) = factory.deploymentForController(deployed.controller);
        assertEq(storedController, deployed.controller);
        assertEq(storedKernel, deployed.kernel);
        assertEq(storedVault, deployed.vault);
        assertEq(storedToken, deployed.token);
        assertEq(storedTeamLocker, deployed.teamLocker);
    }

    function _assertCanonicalRuntime(
        IControllerFactory.Deployment memory deployed,
        address admin,
        address protocolCollector,
        address preMineReceiver
    ) internal {
        assertEq(deployed.kernel.codehash, address(new Kernel(deployed.controller, deployed.vault)).codehash);
        assertEq(deployed.vault.codehash, address(new Vault(deployed.controller, deployed.kernel)).codehash);
        assertEq(
            deployed.token.codehash,
            address(new Token("Enten", "ENTEN", deployed.controller, preMineReceiver, PRE_MINE_AMOUNT, MAX_SUPPLY))
            .codehash
        );
        assertEq(
            deployed.controller.codehash,
            address(new Controller(admin, protocolCollector, deployed.kernel, deployed.vault, deployed.token, 0))
            .codehash
        );
    }
}
