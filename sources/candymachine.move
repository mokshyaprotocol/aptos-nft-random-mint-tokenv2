/// A module for minting NFTs in a random order, it supports:
/// * presale / whitelist
/// * public sale with different amounts
/// * open editions with no limit
module candymachinev2::candymachine {
    use std::signer;
    use std::bcs;
    use std::hash;
    use aptos_std::aptos_hash;
    use aptos_std::from_bcs;
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::event::{EventHandle};
    use aptos_framework::aptos_coin::AptosCoin;
    use candymachinev2::bit_vector::{Self, BitVector};
    use aptos_framework::coin::{Self};
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_token_objects::aptos_token::{Self};
    use aptos_token_objects::royalty::{Self};

    use candymachinev2::bucket_table::{Self, BucketTable};
    use candymachinev2::merkle_proof::{Self};

    /// Caller of transaction is not the creator of the mint
    const EINVALID_SIGNER: u64 = 0;

    /// Royalty denominator must be greater than 0
    const EINVALID_ROYALTY_DENOMINATOR: u64 = 2;

    /// Royalty numerator equal to or less than denominator (<=100% royalties)
    const EINVALID_ROYALTY_NUMERATOR: u64 = 3;

    /// Public sale is not yet started
    const ESALE_NOT_STARTED: u64 = 4;

    /// Mint is sold out
    const ESOLD_OUT: u64 = 5;

    /// Mint is currently paused
    const EPAUSED: u64 = 6;

    /// Collection mutate settings (3 settings) or token mutate settings (5 settings) don't match in length
    const EINVALID_MUTABLE_CONFIG: u64 = 7;

    /// Public sale time must be after presale, and presale must be in the future
    const EINVALID_MINT_TIME: u64 = 8;

    /// Caller has already minted their allowed amount
    const EMINT_LIMIT_EXCEEDED: u64 = 9;

    /// Invalid whitelist proof, either the user isn't whitelisted, or the number of allowed mints doesn't match
    const EINVALID_PROOF: u64 = 10;

    /// Whitelist mint has not started, or it has already become public sale.
    const EWHITELIST_MINT_NOT_ENABLED: u64 = 11;

    /// There are no tokens left to mint
    const EPSEUDORANDOM_REMAINING_IS_ZERO: u64 = 999;

    /// Address for Mokshya mint fees
    const MokshyaFee: address = @0x305d730682a5311fbfc729a51b8eec73924b40849bff25cf9fdb4348cc0a719a;

    /// Numerator for Mokshya fee 3%
    const MINT_FEE_NUMERATOR: u64 = 300;
    /// Denominator for Mokshya fee
    const MINT_FEE_DENOMINATOR: u64 = 10000;

    /// A really large number, when it's an open edition, as many as possible can be minted, and this limit should
    /// likely not be reached
    const OPEN_EDITION_LIMIT: u64 = 100000000;

    /// Configures how the bucket table will behave with different minters.
    const DEFAULT_BUCKET_SIZE: u64 = 4;

    /// Keeps track of the data of all mints by the contract
    struct MintData has key {
        /// Total separate candy machine mints
        total_mints: u64,
        /// Total APT volume in the candy machine mints
        total_apt: u64
    }

    /// A struct describing a mint for a single collection
    struct CandyMachine has key {
        collection_name: String,
        collection_description: String,
        baseuri: String,
        royalty_payee_address: address,
        royalty_points_denominator: u64,
        royalty_points_numerator: u64,
        presale_mint_time: u64,
        public_sale_mint_time: u64,
        presale_mint_price: u64,
        public_sale_mint_price: u64,
        paused: bool,
        total_supply: u64,
        minted: u64,
        token_mutate_setting: vector<bool>,
        candies: BitVector,
        public_mint_limit: u64,
        merkle_root: vector<u8>,
        is_sbt: bool,
        update_event: EventHandle<UpdateCandyEvent>,
        is_openedition: bool,
    }

    /// A list of all whitelisted users, and how many they're whitelisted for
    struct Whitelist has key {
        minters: BucketTable<address, u64>,
    }

    /// A list of all users who have minted, and how much they've minted for a collection
    struct PublicMinters has key {
        minters: BucketTable<address, u64>,
    }

    /// A struct used in an object to hold the information about the Resource Account
    struct ResourceInfo has key {
        /// The creator and owner of the resource account, initialized in `init_candy()`
        source: address,
        /// Signer capability for the resource account
        resource_cap: account::SignerCapability
    }

    /// An event for when the candy machine config is updated
    struct UpdateCandyEvent has drop, store {
        presale_mint_price: u64,
        presale_mint_time: u64,
        public_sale_mint_price: u64,
        public_sale_mint_time: u64,
        royalty_points_denominator: u64,
        royalty_points_numerator: u64,
    }

    /// On creation of the candy machine contract, keep track of the total throughput of the mints
    fun init_module(account: &signer) {
        move_to(account, MintData {
            total_mints: 0,
            total_apt: 0
        })
    }

    /// Initializes a candy machine minter for a collection
    public entry fun init_candy(
        account: &signer,
        collection_name: String,
        collection_description: String,
        baseuri: String,
        royalty_payee_address: address,
        royalty_points_denominator: u64,
        royalty_points_numerator: u64,
        presale_mint_time: u64,
        public_sale_mint_time: u64,
        presale_mint_price: u64,
        public_sale_mint_price: u64,
        total_supply: u64,
        collection_mutate_setting: vector<bool>,
        token_mutate_setting: vector<bool>,
        public_mint_limit: u64,
        is_sbt: bool,
        seeds: vector<u8>,
        is_openedition: bool,
    ) {
        // Validate the mint (this is done prior to resource creation, decreasing gas on failure)
        let now = aptos_framework::timestamp::now_seconds();
        assert!(public_sale_mint_time > presale_mint_time && presale_mint_time >= now, EINVALID_MINT_TIME);
        assert!(
            vector::length(&collection_mutate_setting) == 3 && vector::length(&token_mutate_setting) == 5,
            EINVALID_MUTABLE_CONFIG
        );
        assert!(royalty_points_denominator > 0, EINVALID_ROYALTY_DENOMINATOR);
        assert!(royalty_points_numerator <= royalty_points_denominator, EINVALID_ROYALTY_NUMERATOR);

        // Create the object that will hold the signer capability of the resource account for the collection
        let constructor_ref = object::create_object_from_account(account);
        let object_signer = object::generate_signer(&constructor_ref);

        // Create the resource account which will hold the collection
        let (_resource, resource_cap) = account::create_resource_account(account, seeds);
        let resource_signer_from_cap = account::create_signer_with_capability(&resource_cap);

        // Store the resource cap in teh object
        move_to<ResourceInfo>(
            &object_signer,
            ResourceInfo { resource_cap, source: signer::address_of(account) }
        );

        // Open editions are basically that there are is not a "limit", and it is set to a high number here
        let supply = if (is_openedition) {
            OPEN_EDITION_LIMIT
        } else {
            total_supply
        };

        // Store the new candy machine in the object
        move_to<CandyMachine>(&object_signer, CandyMachine {
            collection_name,
            collection_description,
            baseuri,
            royalty_payee_address,
            royalty_points_denominator,
            royalty_points_numerator,
            presale_mint_time,
            public_sale_mint_time,
            presale_mint_price,
            public_sale_mint_price,
            total_supply: supply,
            minted: 0,
            paused: false,
            candies: bit_vector::new(total_supply),
            token_mutate_setting,
            public_mint_limit,
            merkle_root: vector::empty(),
            is_sbt,
            update_event: account::new_event_handle<UpdateCandyEvent>(&resource_signer_from_cap),
            is_openedition,
        });

        // Create the collection to be minted
        let collection_id = aptos_token::create_collection_object(
            &resource_signer_from_cap,
            collection_description,
            supply,
            collection_name,
            baseuri,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            royalty_points_numerator,
            royalty_points_denominator
        );

        // This changes the royalties payee address from the default (which would be the resource account)
        let royalty = royalty::create(royalty_points_numerator, royalty_points_denominator, royalty_payee_address);
        aptos_token::set_collection_royalties(&resource_signer_from_cap, collection_id, royalty);

        // Store the resource keeping track of who mitned on chain
        move_to(&object_signer, PublicMinters {
            // Can use a different size of bucket table depending on how big we expect the whitelist to be.
            // Here because a global public minting max is optional, we are starting with a smaller size
            // bucket table.
            minters: bucket_table::new<address, u64>(DEFAULT_BUCKET_SIZE),
        });

        // Setup the whitelisting for the multi stage mint
        initialize_whitelist(object_signer)
    }

    /// Mints a single token
    public entry fun mint_script(
        receiver: &signer,
        candy_obj: address,
    ) acquires CandyMachine, MintData, ResourceInfo, PublicMinters {
        let candy_data = borrow_global_mut<CandyMachine>(candy_obj);

        // Check that the sale is running first, to cut down on gas costs for failures
        let now = aptos_framework::timestamp::now_seconds();
        assert!(now > candy_data.public_sale_mint_time, ESALE_NOT_STARTED);

        // Retrieve the mint information, and mint to a user
        let resource_data = borrow_global<ResourceInfo>(candy_obj);
        let candy_admin = resource_data.source;
        let creator = account::create_signer_with_capability(&resource_data.resource_cap);
        let mint_price = candy_data.public_sale_mint_price;
        mint(receiver, &creator, candy_admin, candy_obj, mint_price)
    }

    /// Batch minting multiple tokens at once
    public entry fun mint_script_many(
        receiver: &signer,
        candy_obj: address,
        amount: u64
    ) acquires CandyMachine, MintData, ResourceInfo, PublicMinters {
        let i = 0;

        // TODO: This could be optimized for gas slightly, where mint is called multiple times, rather than mint_script
        while (i < amount) {
            mint_script(receiver, candy_obj);
            i = i + 1
        }
    }

    /// Similar to `mint_script`, but with merkle tree proof verification
    public entry fun mint_from_merkle(
        receiver: &signer,
        candy_obj: address,
        proof: vector<vector<u8>>,
        mint_limit: u64,
    ){
    }

    public entry fun mint_from_merkle_v2(
        receiver: &signer,
        candy_obj: address,
        proof: vector<vector<u8>>,
        mint_limit: u64,
        mint_price: u64,
    ) acquires MintData, CandyMachine, ResourceInfo, Whitelist, PublicMinters {
        let receiver_addr = signer::address_of(receiver);
        let candy_data = borrow_global_mut<CandyMachine>(candy_obj);
        // Proof contains the receiver address, appended with the mint limit and the mint price for the user, ensuring that they can in fact mint
        let leafvec = bcs::to_bytes(&receiver_addr);
        vector::append(&mut leafvec, bcs::to_bytes(&mint_limit));
        vector::append(&mut leafvec, bcs::to_bytes(&mint_price));
        assert!(merkle_proof::verify(proof, candy_data.merkle_root, aptos_hash::keccak256(leafvec)), EINVALID_PROOF);
        // Check if it's presale mint time
        let now = aptos_framework::timestamp::now_seconds();
        let is_whitelist_mint = candy_data.presale_mint_time < now && now < candy_data.public_sale_mint_time;
        assert!(is_whitelist_mint, EWHITELIST_MINT_NOT_ENABLED);

        // Retrieve the minting info
        let resource_data = borrow_global<ResourceInfo>(candy_obj);
        let creator = account::create_signer_with_capability(&resource_data.resource_cap);
        let candy_admin = resource_data.source;
        let mint_data = borrow_global_mut<MintData>(@candymachinev2);

        // let leafvec = bcs::to_bytes(&receiver_addr);
        // vector::append(&mut leafvec, bcs::to_bytes(&mint_limit));
        // vector::append(&mut leafvec, bcs::to_bytes(&EINVALID_ROYALTY_DENOMINATOR));
        // assert!(merkle_proof::verify(proof, candy_data.merkle_root, aptos_hash::keccak256(leafvec)), EINVALID_PROOF);

        // No need to check limit if mint limit = 0, this means the minter can mint unlimited amount of tokens
        if (mint_limit != 0) {
            let whitelist_data = borrow_global_mut<Whitelist>(candy_obj);

            // Initialize first time minting mint limit = 0
            if (!bucket_table::contains(&whitelist_data.minters, &receiver_addr)) {
                bucket_table::add(&mut whitelist_data.minters, receiver_addr, 0);
            };

            // Add one to the count of minted, aborting if it goes over
            let minted_nft = bucket_table::borrow_mut(&mut whitelist_data.minters, receiver_addr);
            assert!(*minted_nft != mint_limit, EMINT_LIMIT_EXCEEDED);
            *minted_nft = *minted_nft + 1;

            // Track the total APT
            mint_data.total_apt = mint_data.total_apt + candy_data.presale_mint_price;
        };

        mint(receiver, &creator, candy_admin, candy_obj, mint_price);
    }
    
    /// Same as mint_from_merkle but a batch amount
    public entry fun mint_from_merkle_many_v2(
        receiver: &signer,
        candy_obj: address,
        proof: vector<vector<u8>>,
        mint_limit: u64,
        amount: u64,
        mint_price:u64
    ) acquires MintData, CandyMachine, ResourceInfo, Whitelist, PublicMinters {
        let i = 0;
        while (i < amount) {
            mint_from_merkle_v2(receiver, candy_obj, proof, mint_limit,mint_price);
            i = i + 1
        }
    }

    /// Same as mint_from_merkle but a batch amount
    public entry fun mint_from_merkle_many(
        receiver: &signer,
        candy_obj: address,
        proof: vector<vector<u8>>,
        mint_limit: u64,
        amount: u64
    ){
        let i = 0;
        while (i < amount) {
            mint_from_merkle(receiver, candy_obj, proof, mint_limit);
            i = i + 1
        }
    }

    /// Internal mint function to mint a single token
    fun mint(
        receiver: &signer,
        creator: &signer,
        candy_admin: address,
        candy_obj: address,
        mint_price: u64
    ) acquires CandyMachine, MintData, PublicMinters {
        let receiver_addr = signer::address_of(receiver);
        let candy_data = borrow_global_mut<CandyMachine>(candy_obj);
        let mint_data = borrow_global_mut<MintData>(@candymachinev2);

        // Ensure that the mint can go on
        assert!(!candy_data.paused, EPAUSED);
        assert!(candy_data.minted != candy_data.total_supply, ESOLD_OUT);

        // If we're in public sale, add the minter, and the amount they've paid to the total
        // Note, when in presale time, this will be added in `mint_from_merkle()`
        let now = aptos_framework::timestamp::now_seconds();
        if (now > candy_data.public_sale_mint_time && candy_data.public_mint_limit != 0) {
            add_public_minter(candy_data, receiver_addr, candy_obj);
            mint_data.total_apt = mint_data.total_apt + candy_data.public_sale_mint_price;
        };

        let baseuri = candy_data.baseuri;
        let token_name = candy_data.collection_name;

        if (candy_data.is_openedition) {
            // Open editions are simple, the name is just the value plus the number minted
            string::append(&mut token_name, string::utf8(b" #"));
            string::append(&mut token_name, num_str(candy_data.minted));
        } else {
            // Non-open editions, randomly choose with a pseudo_random, which one to mint out of the remaining
            let remaining = candy_data.total_supply - candy_data.minted;
            let random_index = pseudo_random(receiver_addr, remaining);
            let required_position = 0; // the number of unset
            let pos = 0; // the mint number
            while (required_position < random_index) {
                if (!bit_vector::is_index_set(&candy_data.candies, pos)) {
                    required_position = required_position + 1;
                };
                if (required_position == random_index) {
                    break
                };
                pos = pos + 1;
            };
            bit_vector::set(&mut candy_data.candies, pos);

            // Build up the name and URI for the randomly chosen token
            let mint_position = pos;
            string::append(&mut baseuri, num_str(mint_position));
            string::append(&mut token_name, string::utf8(b" #"));
            string::append(&mut token_name, num_str(mint_position));
            string::append(&mut baseuri, string::utf8(b".json"));
        };

        // Mint the token, and transfer it to the receiver
        let minted_token = aptos_token::mint_token_object(
            creator,
            candy_data.collection_name,
            candy_data.collection_description,
            token_name,
            baseuri,
            vector::empty<String>(),
            vector::empty<String>(),
            vector::empty()
        );
        object::transfer(creator, minted_token, receiver_addr);

        // Split sale price into Mokshya fee and the collection owner
        let fee = (MINT_FEE_NUMERATOR * mint_price) / MINT_FEE_DENOMINATOR;
        let collection_owner_price = mint_price - fee;
        coin::transfer<AptosCoin>(receiver, MokshyaFee, fee);
        coin::transfer<AptosCoin>(receiver, candy_admin, collection_owner_price);

        // Increment the total mints for the collection
        candy_data.minted = candy_data.minted + 1;

        // Increment the total mints for the contract!
        mint_data.total_mints = mint_data.total_mints + 1
    }

    /// Set the whitelist merkle root, only the creator of the mint can do this
    public entry fun set_root(
        account: &signer,
        candy_obj: address,
        merkle_root: vector<u8>
    ) acquires CandyMachine, ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candy_obj);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let candy_data = borrow_global_mut<CandyMachine>(candy_obj);
        candy_data.merkle_root = merkle_root
    }

    /// Flip mint state between paused and unpaused from whichever it current state is, only the creator of the mint
    /// can do this
    public entry fun pause_resume_mint(
        account: &signer,
        candymachine: address,
    ) acquires ResourceInfo, CandyMachine {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candymachine);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let candy_data = borrow_global_mut<CandyMachine>(candymachine);
        if (candy_data.paused) {
            candy_data.paused = false
        } else {
            candy_data.paused = true
        }
    }

    /// Update whitelist / presale sale time, only creator of mint can do this, and it must be in the future
    public entry fun update_wl_sale_time(
        account: &signer,
        candy_obj: address,
        presale_mint_time: u64
    ) acquires CandyMachine, ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candy_obj);
        let now = aptos_framework::timestamp::now_seconds();
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let candy_data = borrow_global_mut<CandyMachine>(candy_obj);
        assert!(presale_mint_time >= now, EINVALID_MINT_TIME);
        candy_data.presale_mint_time = presale_mint_time;
    }

    /// Update public sale time, only creator of mint can do this, and it must be in the future
    public entry fun update_public_sale_time(
        account: &signer,
        candy_obj: address,
        public_sale_mint_time: u64
    ) acquires CandyMachine, ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candy_obj);
        let now = aptos_framework::timestamp::now_seconds();
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let candy_data = borrow_global_mut<CandyMachine>(candy_obj);
        assert!(public_sale_mint_time >= now, EINVALID_MINT_TIME);
        candy_data.public_sale_mint_time = public_sale_mint_time;
    }

    /// Update public sale price, only creator of mint can do this
    public entry fun update_public_sale_price(
        account: &signer,
        candy_obj: address,
        public_sale_mint_price: u64
    ) acquires CandyMachine, ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candy_obj);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let candy_data = borrow_global_mut<CandyMachine>(candy_obj);
        candy_data.public_sale_mint_price = public_sale_mint_price;
    }

    /// Update whitelist / presale price, only creator of mint can do this
    public entry fun update_wl_sale_price(
        account: &signer,
        candy_obj: address,
        presale_mint_price: u64
    ) acquires CandyMachine, ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candy_obj);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let candy_data = borrow_global_mut<CandyMachine>(candy_obj);
        candy_data.presale_mint_price = presale_mint_price;
    }

    /// Update total supply, only creator of mint can do this
    public entry fun update_total_supply(
        account: &signer,
        candy_obj: address,
        total_supply: u64
    ) acquires CandyMachine, ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candy_obj);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let candy_data = borrow_global_mut<CandyMachine>(candy_obj);
        candy_data.total_supply = total_supply
    }

    /// Update royalty amount, only creator of mint can do this
    /// TODO: Should add royalty rules similar to starting the mint here (some are already applied by aptos_token)
    public entry fun update_royalty<T: key>(
        account: &signer,
        candy_obj: address,
        collection: Object<T>,
        royalty_numerator: u64,
        royalty_denominator: u64,
        payee_address: address,
    ) acquires ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candy_obj);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let resource_signer_from_cap = account::create_signer_with_capability(&resource_data.resource_cap);
        let royalty = royalty::create(royalty_numerator, royalty_denominator, payee_address);
        aptos_token::set_collection_royalties(&resource_signer_from_cap, collection, royalty)
    }

    /// Burns a token in the collection, only creator of mint can do this
    public fun burn_token<T: key>(
        account: &signer,
        candymachine: address,
        token: Object<T>
    ) acquires ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candymachine);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let resource_signer_from_cap = account::create_signer_with_capability(&resource_data.resource_cap);
        aptos_token::burn(&resource_signer_from_cap, token)
    }

    /// Freezes transfer of a token in the collection, only creator of mint can do this
    public fun freeze_transfer<T: key>(
        account: &signer,
        candymachine: address,
        token: Object<T>
    ) acquires ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candymachine);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let resource_signer_from_cap = account::create_signer_with_capability(&resource_data.resource_cap);
        aptos_token::freeze_transfer(&resource_signer_from_cap, token)
    }

    /// Unfreezes transfer of a token in the collection, only creator of mint can do this
    public fun unfreeze_transfer<T: key>(
        account: &signer,
        candymachine: address,
        token: Object<T>
    ) acquires ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candymachine);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let resource_signer_from_cap = account::create_signer_with_capability(&resource_data.resource_cap);
        aptos_token::unfreeze_transfer(&resource_signer_from_cap, token)
    }

    /// Sets the description of a token in the collection, only creator of mint can do this
    public fun set_description<T: key>(
        account: &signer,
        candymachine: address,
        token: Object<T>,
        description: String
    ) acquires ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candymachine);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let resource_signer_from_cap = account::create_signer_with_capability(&resource_data.resource_cap);
        aptos_token::set_description(&resource_signer_from_cap, token, description)
    }

    /// Sets the name of a token in the collection, only creator of mint can do this
    public fun set_name<T: key>(
        account: &signer,
        candymachine: address,
        token: Object<T>,
        name: String
    ) acquires ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candymachine);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let resource_signer_from_cap = account::create_signer_with_capability(&resource_data.resource_cap);
        aptos_token::set_name(&resource_signer_from_cap, token, name)
    }

    /// Sets the uri of a token in the collection, only creator of mint can do this
    public fun set_uri<T: key>(
        account: &signer,
        candymachine: address,
        token: Object<T>,
        uri: String
    ) acquires ResourceInfo {
        let account_addr = signer::address_of(account);
        let resource_data = borrow_global<ResourceInfo>(candymachine);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let resource_signer_from_cap = account::create_signer_with_capability(&resource_data.resource_cap);
        aptos_token::set_uri(&resource_signer_from_cap, token, uri)
    }

    /// Turns a number into a string
    fun num_str(num: u64): String {
        // TODO: this could probably simply be a string format of the number e.g. `0x1::string_utils::format1(&b"{}", num)`
        let v1 = vector::empty();
        while (num / 10 > 0) {
            let rem = num % 10;
            vector::push_back(&mut v1, (rem + 48 as u8));
            num = num / 10;
        };
        vector::push_back(&mut v1, (num + 48 as u8));
        vector::reverse(&mut v1);
        string::utf8(v1)
    }

    /// Generates a pseudorandom number given a `remaining` upper limit
    ///
    /// Will return a number between 1 and remaining, inclusive
    fun pseudo_random(add: address, remaining: u64): u64 {
        // Combine the address, the size, and the time, and hash it
        let x = bcs::to_bytes<address>(&add);
        let y = bcs::to_bytes<u64>(&remaining);
        let z = bcs::to_bytes<u64>(&timestamp::now_seconds());
        vector::append(&mut x, y);
        vector::append(&mut x, z);
        let tmp = hash::sha2_256(x);

        // Retrieve bytes 24 -> 31, to convert into a number
        let data = vector<u8>[];
        let i = 24;
        while (i < 32) {
            let x = vector::borrow(&tmp, i);
            vector::append(&mut data, vector<u8>[*x]);
            i = i + 1;
        };
        assert!(remaining > 0, EPSEUDORANDOM_REMAINING_IS_ZERO);

        let random = from_bcs::to_u64(data) % remaining + 1;
        random
    }

    /// Initializes whitelist bucket
    fun initialize_whitelist(account: signer) {
        move_to(&account, Whitelist {
            minters: bucket_table::new<address, u64>(DEFAULT_BUCKET_SIZE),
        })
    }

    /// Adds a public minter to the mint list
    fun add_public_minter(
        candy_data: &mut CandyMachine,
        receiver_addr: address,
        candy_obj: address
    ) acquires PublicMinters {
        let public_minters = borrow_global_mut<PublicMinters>(candy_obj);

        // Initialize a new minter, with the full mint limit
        if (!bucket_table::contains(&public_minters.minters, &receiver_addr)) {
            bucket_table::add(&mut public_minters.minters, receiver_addr, candy_data.public_mint_limit);
        };

        // Check if they've minted their limit, and decrease their mint limit by one
        let public_minters_limit = bucket_table::borrow_mut(&mut public_minters.minters, receiver_addr);
        assert!(*public_minters_limit != 0, EMINT_LIMIT_EXCEEDED);
        *public_minters_limit = *public_minters_limit - 1;
    }

    /// Withdraws royalty amount from resource account to creator
    public entry fun withdraw_royalty(
        receiver: &signer,
        candymachine: address,
    ) acquires ResourceInfo {
        let account_addr = signer::address_of(receiver);
        let resource_data = borrow_global<ResourceInfo>(candymachine);
        assert!(resource_data.source == account_addr, EINVALID_SIGNER);

        let resource_signer_from_cap = account::create_signer_with_capability(&resource_data.resource_cap);
        coin::transfer<AptosCoin>(
            &resource_signer_from_cap,
            account_addr,
            coin::balance<AptosCoin>(signer::address_of(&resource_signer_from_cap))
        );
    }

    /// In future, if we need to upgrade contract we can use this to get total apt and mints details
    public (friend) fun update_mint_data(price: u64, nfts: u64)acquires MintData{
        let mint_data = borrow_global_mut<MintData>(@candymachinev2);
        mint_data.total_apt = mint_data.total_apt + price;
        mint_data.total_mints = mint_data.total_apt + nfts;
    }

    #[view]
    public fun getPublicMintLimit(minter: address, candymachine: address): u64 acquires PublicMinters{
        let public_minters = borrow_global_mut<PublicMinters>(candymachine);
        if (bucket_table::contains(&public_minters.minters, &minter)) {
            let public_minters_limit = bucket_table::borrow_mut(&mut public_minters.minters, minter);
            return *public_minters_limit
        }
        else {
            return 0
        }
    }
    
    #[view]
    public fun getWhitelistMintLimit(minter: address, candymachine: address): u64 acquires Whitelist{
        let whitelist_data = borrow_global_mut<Whitelist>(candymachine);
        if (bucket_table::contains(&whitelist_data.minters, &minter)) {
            let minted_nft = bucket_table::borrow_mut(&mut whitelist_data.minters, minter);
            return *minted_nft
        }
        else {
            return 0
        }
    }

}