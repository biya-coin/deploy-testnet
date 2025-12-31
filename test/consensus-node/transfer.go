package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strconv"

	"github.com/InjectiveLabs/sdk-go/chain/crypto/ethsecp256k1"
	"github.com/cosmos/cosmos-sdk/codec"
	codectypes "github.com/cosmos/cosmos-sdk/codec/types"
	"github.com/cosmos/cosmos-sdk/std"
	sdk "github.com/cosmos/cosmos-sdk/types"
	authtx "github.com/cosmos/cosmos-sdk/x/auth/tx"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func main() {
	if len(os.Args) < 4 {
		fmt.Println("用法: go run transfer.go <私钥文件> <目标地址> <金额INJ>")
		fmt.Println("示例: go run transfer.go accounts.json inj1xxx... 100")
		os.Exit(1)
	}

	accountsFile := os.Args[1]
	toAddr := os.Args[2]
	amountINJ, _ := strconv.ParseFloat(os.Args[3], 64)
	amount := int64(amountINJ * 1e18)

	// 读取私钥
	data, err := os.ReadFile(accountsFile)
	if err != nil {
		panic(err)
	}

	var keys []string
	if err := json.Unmarshal(data, &keys); err != nil {
		panic(err)
	}

	privKeyBytes, err := base64.StdEncoding.DecodeString(keys[0])
	if err != nil {
		panic(err)
	}

	privKey := &ethsecp256k1.PrivKey{Key: privKeyBytes}
	fromAddr := sdk.AccAddress(privKey.PubKey().Address())

	fmt.Printf("从: %s\n", fromAddr.String())
	fmt.Printf("到: %s\n", toAddr)
	fmt.Printf("金额: %d inj\n\n", amount)

	// 创建编码器
	interfaceRegistry := codectypes.NewInterfaceRegistry()
	std.RegisterInterfaces(interfaceRegistry)
	banktypes.RegisterInterfaces(interfaceRegistry)
	cdc := codec.NewProtoCodec(interfaceRegistry)

	// 连接到节点
	grpcConn, err := grpc.Dial(
		"127.0.0.1:10100",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		panic(err)
	}
	defer grpcConn.Close()

	// 创建转账消息
	msg := banktypes.NewMsgSend(
		fromAddr,
		sdk.MustAccAddressFromBech32(toAddr),
		sdk.NewCoins(sdk.NewInt64Coin("inj", amount)),
	)

	// 构建交易
	txConfig := authtx.NewTxConfig(cdc, authtx.DefaultSignModes)
	txBuilder := txConfig.NewTxBuilder()

	if err := txBuilder.SetMsgs(msg); err != nil {
		panic(err)
	}

	txBuilder.SetGasLimit(200000)
	txBuilder.SetFeeAmount(sdk.NewCoins(sdk.NewInt64Coin("inj", 100000000000)))

	// 获取账户信息
	// ... (需要查询账户序列号)

	// 签名交易
	// ... (使用私钥签名)

	// 广播交易
	// ... (发送到节点)

	fmt.Println("转账完成!")
}
