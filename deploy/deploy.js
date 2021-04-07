let fs = require("fs");
let path = require("path");
const ethers = require("ethers")

const ETHADDR = '0x0000000000000000000000000000000000000000';

let tokens = {
  USDT: '',
  TEXB: '',
}


let Contracts = {

}

let ContractAddress = {}

let config = {
    "url": "",
    "pk": "",
    "gasPrice": "10",
    "users":[]
}

if(fs.existsSync(path.join(__dirname, ".config.json"))) {
    let _config = JSON.parse(fs.readFileSync(path.join(__dirname, ".config.json")).toString());
    for(let k in config) {
        config[k] = _config[k];
    }
}

let ETHER_SEND_CONFIG = {
    gasPrice: ethers.utils.parseUnits(config.gasPrice, "gwei")
}
  

console.log("current endpoint ", config.url)
let provider = new ethers.providers.JsonRpcProvider(config.url)
let owner = new ethers.Wallet(config.pk, provider)

function getWallet(key = config.pk) {
  return new ethers.Wallet(key, provider)
}

console.log('wallet:', getWallet().address)

const sleep = ms =>
  new Promise(resolve =>
    setTimeout(() => {
      resolve()
    }, ms)
  )

async function waitForMint(tx) {
  console.log('tx:', tx)
  let result = null
  do {
    result = await provider.getTransactionReceipt(tx)
    await sleep(100)
  } while (result === null)
  await sleep(200)
}

async function getBlockNumber() {
  return await provider.getBlockNumber()
}

async function deployTokens() {
  let factory = new ethers.ContractFactory(
    ExBasisToken.abi,
    ExBasisToken.bytecode,
    owner
  )
  for (let k in tokens) {
    let decimals = '18'
    if(k=='USDT') decimals = '6'
    let ins = await factory.deploy(ETHER_SEND_CONFIG)
    await waitForMint(ins.deployTransaction.hash)
    tokens[k] = ins.address
    tx = await ins.initialize(
      owner.address, '100000000000000000000000000', '100000000000000000000000000',decimals, k, k,
      ETHER_SEND_CONFIG
    )
    await waitForMint(tx.hash)
  }

}

async function deployContracts() {
  for (let k in Contracts) {
    let factory = new ethers.ContractFactory(
      Contracts[k].abi,
      Contracts[k].bytecode,
      owner
    )
    ins = await factory.deploy(ETHER_SEND_CONFIG)
    await waitForMint(ins.deployTransaction.hash)
    ContractAddress[k] = ins.address
  }
}

async function deploy() {
  console.log('deloy token...')
  await deployTokens();
  // business contract
  console.log('deloy contract...')
  await deployContracts()

}

async function initialize() {

}

function writeAbi() {
  let abis = {}

  for(let k in abis) {
    const abisPath = path.resolve(__dirname, `../abis/${k}.json`);
    fs.writeFileSync(abisPath, JSON.stringify(abis[k], null, 2));
    
    console.log(`Exported abisPath into ${abisPath}`);
  }

}

async function run() {
    console.log('deploy...')
    await deploy()
    console.log('initialize...')
    await initialize()

    console.log('=====Contracts=====')
    for(let k in ContractAddress) {
      console.log(`"${k}": "${ContractAddress[k]}",`)
    }

    console.log('=====Tokens=====')
    for(let k in tokens) {
      console.log(`"${k}": "${tokens[k]}",`)
    }

    writeAbi()
}

if(process.argv[2] == 'abi') {
  writeAbi()
} else {
  run()
}
