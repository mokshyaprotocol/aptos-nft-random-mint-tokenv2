import { HexString,AptosClient, AptosAccount, FaucetClient,TxnBuilderTypes,BCS} from "aptos";
const {
  AccountAddress,
  TypeTagStruct,
  EntryFunction,
  StructTag,
  TransactionPayloadEntryFunction,
  RawTransaction,
  ChainId,
} = TxnBuilderTypes;

import { u64 } from "@saberhq/token-utils";
import keccak256 from "keccak256";
import MerkleTree from "merkletreejs";

const NODE_URL = "https://fullnode.testnet.aptoslabs.com/v1";
const FAUCET_URL = "https://faucet.devnet.aptoslabs.com";

const client = new AptosClient(NODE_URL);
const faucetClient = new FaucetClient(NODE_URL, FAUCET_URL);
var enc = new TextEncoder(); 

// This private key is only for test purpose do not use this in mainnet
const alice = new AptosAccount(HexString.ensure("0x1111111111111111111111111111111111111111111111111111111111111111").toUint8Array());
// This private key is only for test purpose do not use this in mainnet
const bob = new AptosAccount(HexString.ensure("0x2111111111111111111111111111111111111111111111111111111111111111").toUint8Array());

console.log("Alice Address: "+alice.address())
console.log("Bob Address: "+bob.address())

const pid ="0xded9e977cba96693ed36492482490cd8abf7738f9210b2b74a26b5a5d43d9011"

function makeid(length) {
  var result           = '';
  var characters       = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxy';
  var charactersLength = characters.length;
  for ( var i = 0; i < length; i++ ) {
      result += characters.charAt(Math.floor(Math.random() * charactersLength));
  }
  return result;
}
const delay = (delayInms) => {
  return new Promise(resolve => setTimeout(resolve, delayInms));
}

const to_buf = (account: Uint8Array, amount: number, price: number): Buffer => {
  return Buffer.concat([
    account,
    new u64(amount).toArrayLike(Buffer, "le", 8),
    new u64(price).toArrayLike(Buffer, "le", 8),
  ]);
};

describe("whitelist", () => {
  let whitelistAddresses = [
    to_buf(alice.address().toUint8Array(),2,2),
  ];
  for(let i=0;i<200;i++){
    whitelistAddresses.push(to_buf(new AptosAccount().address().toUint8Array(),1,2))
  }
  whitelistAddresses.push(to_buf(alice.address().toUint8Array(),1,2))
  let leafNodes = whitelistAddresses.map((address) => keccak256(address));
  let rt;
  if (leafNodes[0] <= leafNodes[1])
  {
    rt = keccak256(Buffer.concat([leafNodes[0],leafNodes[1]]));
  }
  else
  {
     rt = keccak256(Buffer.concat([leafNodes[1],leafNodes[0]]));
  }
  let tree = new MerkleTree(leafNodes, keccak256, { sortPairs: true });
      // it("Merkle Mint", async () => {
      //   const date = Math.floor(new Date().getTime() / 1000)
      //   const create_candy_machine = {
      //     type: "entry_function_payload",
      //     function: pid+"::candymachine::init_candy",
      //     type_arguments: [],
      //     arguments: [
      //       "Mokshya", // collection name
      //       "This is the description of test collection", // collection description
      //       "https://mint.wapal.io/nft/",  // baseuri 
      //       alice.address(), //royalty_payee_address
      //       "1000", //royalty_points_denominator
      //       "42", //royalty_points_numerator
      //       date+10, //presale_mint_time
      //       date+10000005, //public_sale_mint_time
      //       "1", //presale_mint_price
      //       "1", //public_sale_mint_price
      //       "2000", //total_supply
      //       [false,false,false], //collection_mutate_setting
      //       [false,false,false,false,false], //token_mutate_setting
      //       0, //public_mint_limit
      //       false, //is_sbt
      //       ""+makeid(5), //seeds
      //       true //is_openedition
      //   ]
      //   };
      //   let txnRequest = await client.generateTransaction(alice.address(), create_candy_machine);
      //   let bcsTxn = AptosClient.generateBCSTransaction(alice, txnRequest);
      //   let transactionRes = await client.submitSignedBCSTransaction(bcsTxn);
      //   console.log("Candy Machine created: "+transactionRes.hash)
      //   console.log(transactionRes)
      // })
      it("set root", async () => {
        const mint_token = {
          type: "entry_function_payload",
          function: pid+"::candymachine::set_root",
          type_arguments: [],
          arguments: [
            "0x685702c09979858b3ea5141586468461a06f1db24b9f70ab02f26a85bc80bc20",
            tree.getRoot()
          ]
        };
        let txnRequest = await client.generateTransaction(alice.address(), mint_token);
        let bcsTxn = AptosClient.generateBCSTransaction(alice, txnRequest);
        let transactionRes = await client.submitSignedBCSTransaction(bcsTxn);
        console.log("Root Set "+transactionRes.hash)
      })
      it("Mint", async () => {
        const proofs = [];
        const proof = tree.getProof((keccak256(whitelistAddresses[(whitelistAddresses.length)-1])));
        let not_whitelist= keccak256(whitelistAddresses[1]);
       // 0x50130b2cf86b99972623f93b979ccfda73494b3bc61128b25c88d734d5547cda
         proof.forEach((p) => {
           proofs.push(p.data);
         });
        const mint_token = {
          type: "entry_function_payload",
          function: pid+"::candymachine::mint_from_merkle",
          type_arguments: [],
          arguments: [
            "0x685702c09979858b3ea5141586468461a06f1db24b9f70ab02f26a85bc80bc20",
            proofs,
            1
        ]
        };
        let txnRequest = await client.generateTransaction(alice.address(), mint_token);
        let bcsTxn = AptosClient.generateBCSTransaction(alice, txnRequest);
        let transactionRes = await client.submitSignedBCSTransaction(bcsTxn);
        console.log("Token Minted "+transactionRes.hash)
      })
      // it("Burn", async () => {
      //   const mint_token = {
      //     type: "entry_function_payload",
      //     function: pid+"::candymachine::burn_token",
      //     type_arguments: [],
      //     arguments: [
      //       "0x5f2c44aae1e80f667b41e2595fe7800cb9620a8224450a911608d30fd9091fb5"
      //   ]
      //   };
      //   let txnRequest = await client.generateTransaction(bob.address(), mint_token);
      //   let bcsTxn = AptosClient.generateBCSTransaction(bob, txnRequest);
      //   let transactionRes = await client.submitSignedBCSTransaction(bcsTxn);
      //   console.log("Token Minted "+transactionRes.hash)
      // })
  })