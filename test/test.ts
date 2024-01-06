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

const pid ="0x6547d9f1d481fdc21cd38c730c07974f2f61adb7063e76f9d9522ab91f090dac"

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

describe("whitelist", () => {
  it("Merkle Mint", async () => {
        const date = Math.floor(new Date().getTime() / 1000)
        const create_candy_machine = {
          type: "entry_function_payload",
          function: pid+"::candymachine::init_candy",
          type_arguments: [],
          arguments: [
            "Mokshya", // collection name
            "This is the description of test collection", // collection description
            "https://mint.wapal.io/nft/",  // collection 
            alice.address(),
            "1000",
            "42",
            date+10,
            date+15,
            "1",
            "1",
            "2000",
            [false,false,false],
            [false,false,false,false,false],
            0,
            false,
            ""+makeid(5),
            true
        ]
        };
        let txnRequest = await client.generateTransaction(alice.address(), create_candy_machine);
        let bcsTxn = AptosClient.generateBCSTransaction(alice, txnRequest);
        let transactionRes = await client.submitSignedBCSTransaction(bcsTxn);
        console.log("Candy Machine created: "+transactionRes.hash)
        console.log(transactionRes)
      })
      it("Mint", async () => {
        const mint_token = {
          type: "entry_function_payload",
          function: pid+"::candymachine::mint_script",
          type_arguments: [],
          arguments: [
            "0x8bac40d532374ac5f6820148b7f564a3f26465f3e4c4af85126bcc5a470aa096"
        ]
        };
        let txnRequest = await client.generateTransaction(bob.address(), mint_token);
        let bcsTxn = AptosClient.generateBCSTransaction(bob, txnRequest);
        let transactionRes = await client.submitSignedBCSTransaction(bcsTxn);
        console.log("Token Minted "+transactionRes.hash)
      })
      it("Burn", async () => {
        const mint_token = {
          type: "entry_function_payload",
          function: pid+"::candymachine::burn_token",
          type_arguments: [],
          arguments: [
            "0x5f2c44aae1e80f667b41e2595fe7800cb9620a8224450a911608d30fd9091fb5"
        ]
        };
        let txnRequest = await client.generateTransaction(bob.address(), mint_token);
        let bcsTxn = AptosClient.generateBCSTransaction(bob, txnRequest);
        let transactionRes = await client.submitSignedBCSTransaction(bcsTxn);
        console.log("Token Minted "+transactionRes.hash)
      })
  })