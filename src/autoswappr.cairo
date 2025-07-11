#[starknet::contract]
// @title AutoSwappr Contract
// @dev Implements upgradeable pattern and ownership control

pub mod AutoSwappr {
    // External imports
    use pragma_lib::abi::{IPragmaABIDispatcher, IPragmaABIDispatcherTrait};
    use pragma_lib::types::{AggregationMode, DataType, PragmaPricesResponse};
    use alexandria_math::fast_power::fast_power;

    // Ekubo imports
    use ekubo::interfaces::core::{ILocker, ICoreDispatcher, ICoreDispatcherTrait};

    // OZ imports
    use openzeppelin_upgrades::UpgradeableComponent;
    use openzeppelin_upgrades::interface::IUpgradeable;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};

    use starknet::storage::{Map, StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{
        ContractAddress, get_caller_address, contract_address_const, get_contract_address, ClassHash
    };

    // Package imports
    use crate::base::errors::Errors;
    use crate::interfaces::iautoswappr::{IAutoSwappr, ContractInfo};
    use crate::base::types::{Route, Assets, RouteParams, SwapParams, FeeType, SwapData, SwapResult};
    use crate::components::operator::OperatorComponent;
    use crate::interfaces::iavnu_exchange::{IExchangeDispatcher, IExchangeDispatcherTrait};
    use crate::interfaces::ifibrous_exchange::{
        IFibrousExchangeDispatcher, IFibrousExchangeDispatcherTrait
    };

    // Core imports
    use core::integer::{u256, u128};
    use core::num::traits::Zero;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: OperatorComponent, storage: operator, event: OperatorEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl OperatorImpl = OperatorComponent::OperatorComponent<ContractState>;


    // @notice Storage struct containing all contract state variables
    // @dev Includes mappings for supported assets and critical contract addresses
    #[storage]
    struct Storage {
        fees_collector: ContractAddress,
        fee_amount_bps: u8, // fixed fee in bps;  50 = 0.5$ fee
        fee_type: FeeType,
        percentage_fee_bps: u16, // Percentage fee in basis points (e.g., 100 = 1%)
        avnu_exchange_address: ContractAddress,
        fibrous_exchange_address: ContractAddress,
        ekubo_core_address: ContractAddress,
        oracle_address: ContractAddress,
        supported_assets_to_feed_id: Map<ContractAddress, felt252>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        operator: OperatorComponent::Storage,
    }

    // @notice Events emitted by the contract
    #[event]
    #[derive(starknet::Event, Drop)]
    pub enum Event {
        SwapSuccessful: SwapSuccessful,
        Subscribed: Subscribed,
        Unsubscribed: Unsubscribed,
        FeeTypeChanged: FeeTypeChanged,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        OperatorEvent: OperatorComponent::Event,
    }

    // @notice Event emitted when a swap is successfully executed
    // @param token_from_address Address of the token being sold
    // @param token_from_amount Amount of tokens being sold
    // @param token_to_address Address of the token being bought
    // @param token_to_amount Amount of tokens being bought
    // @param beneficiary Address receiving the bought tokens
    #[derive(Drop, starknet::Event)]
    pub struct SwapSuccessful {
        pub token_from_address: ContractAddress,
        pub token_from_amount: u256,
        pub token_to_address: ContractAddress,
        pub token_to_amount: u256,
        pub beneficiary: ContractAddress,
        pub provider: ContractAddress
    }

    #[derive(starknet::Event, Drop)]
    pub struct Subscribed {
        pub user: ContractAddress,
        pub assets: Assets,
    }

    #[derive(starknet::Event, Drop)]
    pub struct Unsubscribed {
        pub user: ContractAddress,
        pub assets: Assets,
        pub block_timestamp: u64
    }

    #[derive(Copy, Drop, Debug, PartialEq, starknet::Event)]
    pub struct FeeTypeChanged {
        pub new_fee_type: FeeType,
        pub new_percentage_fee: u16,
    }


    const MAX_FEE_PERCENTAGE: u16 = 300; // 3% in basis points (300 basis points)

    #[constructor]
    fn constructor(
        ref self: ContractState,
        fees_collector: ContractAddress,
        fee_amount_bps: u8,
        avnu_exchange_address: ContractAddress,
        fibrous_exchange_address: ContractAddress,
        ekubo_core_address: ContractAddress,
        oracle_address: ContractAddress,
        supported_assets: Array<ContractAddress>,
        supported_assets_priceFeeds_ids: Array<felt252>,
        owner: ContractAddress,
        initial_fee_type: FeeType,
        initial_percentage_fee: u16,
    ) {
        assert(
            !supported_assets.is_empty()
                && supported_assets.len() == supported_assets_priceFeeds_ids.len(),
            Errors::INVALID_INPUT
        );

        for i in 0
            ..supported_assets
                .len() {
                    self
                        .supported_assets_to_feed_id
                        .write(*supported_assets[i], *supported_assets_priceFeeds_ids[i]);
                };
        self.fees_collector.write(fees_collector);
        self.fee_amount_bps.write(fee_amount_bps);
        self.fibrous_exchange_address.write(fibrous_exchange_address);
        self.avnu_exchange_address.write(avnu_exchange_address);
        self.ekubo_core_address.write(ekubo_core_address);
        self.oracle_address.write(oracle_address);
        self.ownable.initializer(owner);
        self.fee_type.write(initial_fee_type);
        self.percentage_fee_bps.write(initial_percentage_fee);
    }


    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            self.upgradeable.upgrade(new_class_hash);
        }
    }


    #[abi(embed_v0)]
    impl AutoSwappr of IAutoSwappr<ContractState> {
        fn avnu_swap(
            ref self: ContractState,
            protocol_swapper: ContractAddress,
            token_from_address: ContractAddress,
            token_from_amount: u256,
            token_to_address: ContractAddress,
            token_to_min_amount: u256,
            beneficiary: ContractAddress,
            integrator_fee_amount_bps: u128,
            integrator_fee_recipient: ContractAddress,
            routes: Array<Route>,
        ) {
            assert(self.operator.is_operator(get_caller_address()), Errors::INVALID_SENDER);

            assert(!token_from_amount.is_zero(), Errors::ZERO_AMOUNT);
            let (supported, _) = self.get_token_from_status_and_value(token_from_address);
            assert(supported, Errors::UNSUPPORTED_TOKEN,);

            let this_contract = get_contract_address();
            let token_from_contract = ERC20ABIDispatcher { contract_address: token_from_address };
            let token_to_contract = ERC20ABIDispatcher { contract_address: token_to_address };

            assert(
                token_from_contract.allowance(protocol_swapper, this_contract) >= token_from_amount,
                Errors::INSUFFICIENT_ALLOWANCE,
            );

            token_from_contract.transfer_from(protocol_swapper, this_contract, token_from_amount);
            let avnu_addr = self.avnu_exchange_address.read();
            token_from_contract.approve(avnu_addr, token_from_amount);
            let contract_token_to_balance = token_to_contract.balance_of(this_contract);

            let swap = self
                ._avnu_swap(
                    token_from_address,
                    token_from_amount,
                    token_to_address,
                    token_to_min_amount,
                    // beneficiary,
                    this_contract, // only caller address can be the beneficiary, in this case, the contract. 
                    integrator_fee_amount_bps,
                    integrator_fee_recipient,
                    routes
                );
            assert(swap, Errors::SWAP_FAILED);
            let new_contract_token_to_balance = token_to_contract.balance_of(this_contract);
            let token_to_received = new_contract_token_to_balance - contract_token_to_balance;
            let updated_token_to_received = self
                ._collect_fees(token_to_received, token_to_contract);
            token_to_contract.transfer(beneficiary, updated_token_to_received);

            self
                .emit(
                    SwapSuccessful {
                        token_from_address,
                        token_from_amount,
                        token_to_address,
                        token_to_amount: token_to_received,
                        beneficiary,
                        provider: avnu_addr
                    }
                );
        }

        fn fibrous_swap(
            ref self: ContractState,
            routeParams: RouteParams,
            swapParams: Array<SwapParams>,
            protocol_swapper: ContractAddress,
            beneficiary: ContractAddress
        ) {
            let contract_address = get_contract_address();

            // assertions
            assert(self.operator.is_operator(get_caller_address()), Errors::INVALID_SENDER,);
            let (supported, _) = self.get_token_from_status_and_value(routeParams.token_in);
            assert(supported, Errors::UNSUPPORTED_TOKEN,);
            assert(!routeParams.amount_in.is_zero(), Errors::ZERO_AMOUNT);
            assert(routeParams.destination == contract_address, Errors::INVALID_SENDER);

            let token_in_contract = ERC20ABIDispatcher { contract_address: routeParams.token_in };
            let token_out_contract = ERC20ABIDispatcher { contract_address: routeParams.token_out };
            assert(
                token_in_contract
                    .allowance(protocol_swapper, contract_address) >= routeParams
                    .amount_in,
                Errors::INSUFFICIENT_ALLOWANCE,
            );

            // Approve commission taking from fibrous
            token_in_contract
                .transfer_from(protocol_swapper, contract_address, routeParams.amount_in);
            let fibrous_addr = self.fibrous_exchange_address.read();
            token_in_contract.approve(fibrous_addr, routeParams.amount_in);
            let contract_token_out_balance = token_out_contract.balance_of(contract_address);
            self._fibrous_swap(routeParams.clone(), swapParams,);

            let new_contract_token_out_balance = token_out_contract.balance_of(contract_address);
            let token_out_received = new_contract_token_out_balance - contract_token_out_balance;
            let updated_token_out_received = self
                ._collect_fees(token_out_received, token_out_contract);
            token_out_contract.transfer(beneficiary, updated_token_out_received);

            self
                .emit(
                    SwapSuccessful {
                        token_from_address: routeParams.token_in,
                        token_from_amount: routeParams.amount_in,
                        token_to_address: routeParams.token_out,
                        token_to_amount: token_out_received,
                        beneficiary,
                        provider: fibrous_addr
                    }
                );
        }

        fn ekubo_swap(ref self: ContractState, swap_data: SwapData) -> SwapResult {
            let contract_address = get_contract_address();

            // assertions
            assert(self.operator.is_operator(get_caller_address()), Errors::INVALID_SENDER);
            assert(!swap_data.params.amount.mag.is_zero(), Errors::ZERO_AMOUNT);
            let token_in = if swap_data.params.is_token1 {
                swap_data.pool_key.token1
            } else {
                swap_data.pool_key.token0
            };
            let (supported, _) = self.get_token_from_status_and_value(token_in);
            assert(supported, Errors::UNSUPPORTED_TOKEN);
            let protocol_swapper = swap_data.caller;
            let token_in_contract = ERC20ABIDispatcher { contract_address: token_in };
            assert(
                token_in_contract
                    .allowance(protocol_swapper, contract_address) >= swap_data
                    .params
                    .amount
                    .mag
                    .into(),
                Errors::INSUFFICIENT_ALLOWANCE,
            );

            token_in_contract
                .transfer_from(
                    protocol_swapper, contract_address, swap_data.params.amount.mag.into()
                );
            ekubo::components::shared_locker::call_core_with_callback(
                ICoreDispatcher { contract_address: self.ekubo_core_address.read() }, @swap_data
            )
        }

        // Manual swap function for Ekubo. Allows users to swap tokens directly on ekubo
        fn ekubo_manual_swap(ref self: ContractState, swap_data: SwapData) -> SwapResult {
            let contract_address = get_contract_address();
            let sender_address = get_caller_address();

            // assertions
            //assert(self.operator.is_operator(get_caller_address()), Errors::INVALID_SENDER);
            assert(!swap_data.params.amount.mag.is_zero(), Errors::ZERO_AMOUNT);
            let token_in = if swap_data.params.is_token1 {
                swap_data.pool_key.token1
            } else {
                swap_data.pool_key.token0
            };
            let (supported, _) = self.get_token_from_status_and_value(token_in);
            assert(supported, Errors::UNSUPPORTED_TOKEN);
            // let protocol_swapper = swap_data.caller;
            let token_in_contract = ERC20ABIDispatcher { contract_address: token_in };
            assert(
                token_in_contract
                    .allowance(sender_address, contract_address) >= swap_data
                    .params
                    .amount
                    .mag
                    .into(),
                Errors::INSUFFICIENT_ALLOWANCE,
            );
            token_in_contract
                .transfer_from(
                    sender_address, contract_address, swap_data.params.amount.mag.into()
                );
            ekubo::components::shared_locker::call_core_with_callback(
                ICoreDispatcher { contract_address: self.ekubo_core_address.read() }, @swap_data
            )
        }

        fn get_token_amount_in_usd(
            self: @ContractState, token: ContractAddress, token_amount: u256
        ) -> u256 {
            let feed_id = self.supported_assets_to_feed_id.read(token);
            let (price, decimals) = self.get_asset_price_median(DataType::SpotEntry(feed_id));
            price.into() * token_amount / fast_power(10_u32, decimals).into()
        }


        fn support_new_token_from(
            ref self: ContractState, token_from: ContractAddress, feed_id: felt252
        ) {
            self.ownable.assert_only_owner();
            assert(!(feed_id == ''), Errors::INVALID_INPUT);
            let (supported, _) = self.get_token_from_status_and_value(token_from);
            assert(!supported, Errors::EXISTING_ADDRESS);
            self.supported_assets_to_feed_id.write(token_from, feed_id);
        }

        fn remove_token_from(ref self: ContractState, token_from: ContractAddress) {
            self.ownable.assert_only_owner();
            let (supported, _) = self.get_token_from_status_and_value(token_from);
            assert(supported, Errors::UNSUPPORTED_TOKEN);
            self.supported_assets_to_feed_id.write(token_from, '');
        }

        fn get_token_from_status_and_value(
            self: @ContractState, token_from: ContractAddress
        ) -> (bool, felt252) {
            let price_feed_id = self.supported_assets_to_feed_id.read(token_from);
            let supported = !(price_feed_id == '');
            (supported, price_feed_id)
        }

        fn contract_parameters(self: @ContractState) -> ContractInfo {
            ContractInfo {
                fees_collector: self.fees_collector.read(),
                fibrous_exchange_address: self.fibrous_exchange_address.read(),
                avnu_exchange_address: self.avnu_exchange_address.read(),
                oracle_address: self.oracle_address.read(),
                owner: self.ownable.owner(),
                fee_type: self.fee_type.read(),
                percentage_fee: self.percentage_fee_bps.read()
            }
        }

        fn set_fee_type(ref self: ContractState, fee_type: FeeType, percentage_fee: u16) {
            self.ownable.assert_only_owner();
            assert(percentage_fee <= MAX_FEE_PERCENTAGE, Errors::INVALID_INPUT); // Max 3% fee
            self.fee_type.write(fee_type);
            self.percentage_fee_bps.write(percentage_fee);
            self
                .emit(
                    FeeTypeChanged { new_fee_type: fee_type, new_percentage_fee: percentage_fee }
                );
        }
    }

    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let ekubo_core_addr = self.ekubo_core_address.read();
            let core = ICoreDispatcher { contract_address: ekubo_core_addr };
            ekubo::components::shared_locker::check_caller_is_core(core);
            let contract_address = get_contract_address();
            let SwapData { pool_key, params, caller, } =
                ekubo::components::shared_locker::consume_callback_data::<
                SwapData
            >(core, data);
            let delta = core.swap(pool_key, params);
            ekubo::components::shared_locker::handle_delta(
                core, pool_key.token0, delta.amount0, contract_address,
            );
            ekubo::components::shared_locker::handle_delta(
                core, pool_key.token1, delta.amount1, contract_address,
            );
            // fee collection
            // when delta sign is negative, it means the token is token_out
            let (token_in, token_out, amount_in, amount_out) = if delta.amount0.sign {
                (pool_key.token1, pool_key.token0, delta.amount1.mag, delta.amount0.mag)
            } else {
                (pool_key.token0, pool_key.token1, delta.amount0.mag, delta.amount1.mag)
            };
            let token_out_contract = ERC20ABIDispatcher { contract_address: token_out };
            let token_to_received = self._collect_fees(amount_out.into(), token_out_contract);
            token_out_contract.transfer(caller, token_to_received);

            //TODO: Implement slippage check?

            self
                .emit(
                    SwapSuccessful {
                        token_from_address: token_in,
                        token_from_amount: amount_in.into(),
                        token_to_address: token_out,
                        token_to_amount: token_to_received,
                        beneficiary: caller,
                        provider: ekubo_core_addr
                    }
                );
            let swap_result = SwapResult { delta };
            let mut arr: Array<felt252> = ArrayTrait::new();
            Serde::serialize(@swap_result, ref arr);
            arr.span()
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _avnu_swap(
            ref self: ContractState,
            token_from_address: ContractAddress,
            token_from_amount: u256,
            token_to_address: ContractAddress,
            token_to_min_amount: u256,
            beneficiary: ContractAddress,
            integrator_fee_amount_bps: u128,
            integrator_fee_recipient: ContractAddress,
            routes: Array<Route>,
        ) -> bool {
            let avnu = IExchangeDispatcher { contract_address: self.avnu_exchange_address.read() };

            avnu
                .multi_route_swap(
                    token_from_address,
                    token_from_amount,
                    token_to_address,
                    // using token_to_min_amount as token_to_amount as token_to_amount doesn't
                    // actually do anything in avnu
                    token_to_min_amount,
                    token_to_min_amount,
                    beneficiary,
                    integrator_fee_amount_bps,
                    integrator_fee_recipient,
                    routes
                )
        }

        fn _fibrous_swap(
            ref self: ContractState, routeParams: RouteParams, swapParams: Array<SwapParams>,
        ) {
            let fibrous = IFibrousExchangeDispatcher {
                contract_address: self.fibrous_exchange_address.read()
            };

            fibrous.swap(routeParams, swapParams);
        }

        fn get_asset_price_median(self: @ContractState, asset: DataType) -> (u128, u32) {
            let oracle_dispatcher = IPragmaABIDispatcher {
                contract_address: self.oracle_address.read()
            };
            let output: PragmaPricesResponse = oracle_dispatcher
                .get_data(asset, AggregationMode::Median(()));
            return (output.price, output.decimals);
        }

        fn _collect_fees(
            ref self: ContractState, token_to_received: u256, token_to_contract: ERC20ABIDispatcher
        ) -> u256 {
            // Retrieve the number of decimal places for the token
            let token_to_decimals: u128 = token_to_contract.decimals().into();
            assert(token_to_decimals > 0, Errors::INVALID_DECIMALS);

            let fee: u256 = match self.fee_type.read() {
                FeeType::Fixed => {
                    // Fixed fee calculation
                    (self.fee_amount_bps.read().into()
                        * fast_power(10_u128, token_to_decimals)
                        / 100)
                        .into()
                },
                FeeType::Percentage => {
                    // Percentage fee calculation
                    token_to_received * self.percentage_fee_bps.read().into() / 10000
                }
            };

            token_to_contract.transfer(self.fees_collector.read(), fee);
            token_to_received - fee
        }

        // @notice Returns the zero address constant
        fn zero_address(self: @ContractState) -> ContractAddress {
            contract_address_const::<0>()
        }
    }

    fn is_non_zero(address: ContractAddress) -> bool {
        address.into() != 0
    }
}
