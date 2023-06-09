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
;
// This private key is only for test purpose do not use this in mainnet
const bob = new AptosAccount(HexString.ensure("0x2111111111111111111111111111111111111111111111111111111111111111").toUint8Array());

console.log("Alice Address: "+alice.address())
console.log("Bob Address: "+bob.address())

const pid ="0xc2182d93cca4457c35be34defd879a0f61c9ebd6444b634729b5d44442e1caf4"

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
            "https://mokshya.io/nft/",  // collection 
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
        ]
        };
        // let txnRequest = await client.generateTransaction(alice.address(), create_candy_machine);
        // let bcsTxn = AptosClient.generateBCSTransaction(alice, txnRequest);
        // let transactionRes = await client.submitSignedBCSTransaction(bcsTxn);
        // console.log("Candy Machine created: "+transactionRes.hash)
        const mint_script = {
          type: "entry_function_payload",
          function: pid+"::candymachine::mint_script",
          type_arguments: [],
          arguments: [
            "0xf4256e2e0ffc494f1d18e653c867a369d78dc134badddd14ab3b6ecb7bfbf685",
            "0xf4256e2e0ffc494f1d18e653c867a369d78dc134badddd14ab3b6ecb7bfbf685"
        ]
        };
        const cc = new AptosAccount(Buffer.from("0xf4256e2e0ffc494f1d18e653c867a369d78dc134badddd14ab3b6ecb7bfbf685"))
        let txnRequest = await client.generateTransaction(bob.address(), mint_script);
        let bcsTxn = AptosClient.generateBCSTransaction(cc, txnRequest);
        console.log(bcsTxn)
        let transactionRes = await client.submitSignedBCSTransaction(bcsTxn);
        console.log("Mint successfull: "+transactionRes.hash)
    })
  })