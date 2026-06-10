# TC367 ASCLIN SPI 学习整理

## 1. 资料来源

本笔记基于当前工程内的 Infineon AURIX TC3xx iLLD 1.20.0：

- 驱动头文件：`Libraries/iLLD/TC3xx/Tricore/Asclin/Spi/IfxAsclin_Spi.h`
- 驱动源文件：`Libraries/iLLD/TC3xx/Tricore/Asclin/Spi/IfxAsclin_Spi.c`
- 标准 ASCLIN 底层：`Libraries/iLLD/TC3xx/Tricore/Asclin/Std/IfxAsclin.h`
- 寄存器定义：`Libraries/Infra/Sfr/TC36x/IfxAsclin_*`
- TC367 LFBGA292 引脚映射：`Libraries/iLLD/TC3xx/Tricore/_PinMap/TC36x/IfxAsclin_PinMap_TC36x_LFBGA292.*`
- TC36x ASCLIN 资源配置：`Libraries/iLLD/TC3xx/Tricore/_Impl/IfxAsclin_cfg_TC36x.h`

当前 TC36x 配置中共有 12 个 ASCLIN 模块：`ASCLIN0` 到 `ASCLIN11`。

## 2. ASCLIN SPI 是什么

ASCLIN 是 AURIX 里的通用串行模块，全称通常理解为 Asynchronous/Synchronous Interface。它可以配置成多种通信模式：

- ASC：异步串口，也就是 UART/RS232/RS485 常用模式。
- SPI：同步串行模式。
- LIN：LIN 总线模式。

本工程里的 `IfxAsclin_Spi` 是 iLLD 对 ASCLIN SPI 模式的封装。需要特别注意：

- `IfxAsclin_Spi` 只支持 SPI Master。
- 支持 8 bit 和 16 bit 数据宽度。
- 数据传输依赖 ASCLIN 硬件 FIFO。
- TX/RX 数据搬运主要通过中断后台完成。
- 接口风格是非阻塞启动传输，应用层用 `IfxAsclin_Spi_getStatus()` 查询是否完成。

## 3. ASCLIN SPI 与 QSPI 的关系

TC367 上做 SPI 通信通常优先考虑 QSPI，因为 QSPI 是专用 SPI 外设；ASCLIN SPI 更适合在 QSPI 资源不够、板级引脚正好接在 ASCLIN、或低速同步通信时使用。

| 对比项 | ASCLIN SPI | QSPI |
| --- | --- | --- |
| 外设定位 | ASCLIN 多功能串行模式之一 | 专用 SPI/QSPI 外设 |
| iLLD 驱动 | `IfxAsclin_Spi` | `IfxQspi_SpiMaster` |
| 工作模式 | 仅 Master | Master/更完整的 SPI 场景 |
| 数据宽度 | 8/16 bit 为主 | 更丰富 |
| FIFO | 有 | 有 |
| 多从机能力 | 有 SLSO，但能力较简单 | 更适合多片选、多通道 |
| 推荐用途 | 资源补充、简单 SPI | 主 SPI 方案 |

如果后续要写通用 `BSW_SPI`，建议默认基于 QSPI；如果某一路硬件实际接在 ASCLIN 的 SCLK/TX/RX/SLSO 上，再单独做 `BSW_ASCLIN_SPI` 或 SPI backend。

## 4. 核心数据结构

### 4.1 `IfxAsclin_Spi`

这是运行时句柄，应用层通常定义成全局或静态全局变量：

```c
static IfxAsclin_Spi g_asclinSpi;
```

内部关键成员：

- `asclin`：指向具体 ASCLIN 寄存器，例如 `&MODULE_ASCLIN1`。
- `txJob`：当前发送任务。
- `rxJob`：当前接收任务。
- `sending`：驱动锁，防止一次传输未完成又启动下一次。
- `errorFlags`：错误标志。
- `dataWidth`：实际数据宽度，8 bit 时为 1，16 bit 时为 2。
- `transferInProgress`：传输进行中状态。

### 4.2 `IfxAsclin_Spi_Config`

这是初始化配置结构体。一般先调用默认配置函数：

```c
IfxAsclin_Spi_Config spiConfig;
IfxAsclin_Spi_initModuleConfig(&spiConfig, &MODULE_ASCLIN1);
```

然后再修改波特率、中断、引脚、数据宽度、CPOL/SPOL 等配置。

关键配置项：

- `frameMode`：应为 `IfxAsclin_FrameMode_spi`。
- `clockSource`：默认是 `IfxAsclin_ClockSource_ascFastClock`。
- `baudrate.baudrate`：SPI 时钟频率。
- `baudrate.prescaler`：预分频。
- `baudrate.oversampling`：过采样因子。
- `inputOutput.alti`：RX 输入复用选择，由 RX pin 对应的 `select` 决定。
- `inputOutput.cpol`：时钟空闲电平。
- `inputOutput.spol`：片选空闲电平。
- `inputOutput.loopBack`：内部回环测试。
- `frame.shiftDir`：MSB first 或 LSB first。
- `dataLength`：每帧数据位宽，常用 `IfxAsclin_DataLength_8`。
- `fifo`：FIFO 入口/出口宽度、触发水位、FIFO 模式。
- `interrupt`：TX/RX/ER 中断优先级和服务 CPU。
- `pins`：SCLK/RX/TX/SLSO 引脚。

### 4.3 `IfxAsclin_Spi_Pins`

ASCLIN SPI 需要 4 类引脚：

```c
const IfxAsclin_Spi_Pins pins = {
    &IfxAsclin1_SCLK_P15_0_OUT, IfxPort_OutputMode_pushPull,
    &IfxAsclin1_RXA_P15_1_IN,   IfxPort_InputMode_pullUp,
    &IfxAsclin1_TX_P15_4_OUT,   IfxPort_OutputMode_pushPull,
    &IfxAsclin1_SLSO_P20_8_OUT, IfxPort_OutputMode_pushPull,
    IfxPort_PadDriver_cmosAutomotiveSpeed1
};
```

字段顺序是：

1. SCLK 输出引脚和输出模式。
2. RX 输入引脚和输入模式。
3. TX 输出引脚和输出模式。
4. SLSO 片选输出引脚和输出模式。
5. Pad driver。

注意：示例里的引脚只是 iLLD 头文件示例，不代表当前板子一定这样连接。实际开发必须以原理图或 pinmapper 配置为准。

## 5. 默认配置

`IfxAsclin_Spi_initModuleConfig()` 给出的默认配置大致如下：

- SPI 模式：`IfxAsclin_FrameMode_spi`
- 时钟源：`IfxAsclin_ClockSource_ascFastClock`
- RX 输入选择：`IfxAsclin_RxInputSelect_0`
- CPOL：`IfxAsclin_ClockPolarity_idleLow`
- SPOL：`IfxAsclin_SlavePolarity_idlehigh`
- Loopback：关闭
- 默认波特率：`100000.0f`
- Prescaler：`2`
- Oversampling：`IfxAsclin_OversamplingFactor_8`
- Median filter：`IfxAsclin_SamplesPerBit_one`
- Idle delay：0
- Lead delay：1
- Stop bit / trail delay：1
- Shift direction：`IfxAsclin_ShiftDirection_lsbFirst`
- Data length：`IfxAsclin_DataLength_8`
- RX FIFO 模式：`IfxAsclin_ReceiveBufferMode_rxFifo`
- TX/RX/ER 中断优先级：默认 0，即不启用
- 中断服务目标：默认 CPU0
- Pins：默认 `NULL_PTR`

实际项目里，最少要改：

- `baudrate.baudrate`
- `interrupt.txPriority`
- `interrupt.rxPriority`
- `interrupt.erPriority`
- `interrupt.typeOfService`
- `pins`
- `inputOutput.alti`
- 根据从设备要求修改 `cpol`、`spol`、`shiftDir`、`dataLength`

## 6. 初始化流程

典型流程如下：

1. 定义全局句柄和缓冲区。
2. 定义 TX/RX/ER 中断优先级。
3. 实现 3 个 ISR，分别调用 iLLD 的中断处理函数。
4. 创建 `IfxAsclin_Spi_Config`。
5. 调用 `IfxAsclin_Spi_initModuleConfig()` 填默认值。
6. 配置波特率、数据位宽、时钟极性、片选极性、移位方向。
7. 配置中断优先级和 `typeOfService`。
8. 配置 SCLK/RX/TX/SLSO 引脚。
9. 调用 `IfxAsclin_Spi_initModule()` 初始化硬件。
10. 传输前调用 `IfxAsclin_Spi_getStatus()` 判断是否空闲。
11. 调用 `IfxAsclin_Spi_exchange()` 启动传输。
12. 等待状态回到 `IfxAsclin_Spi_Status_ok`。

## 7. 中断处理

ASCLIN SPI 需要 3 类中断：

```c
IFX_INTERRUPT(asclin1TxISR, 0, IFX_INTPRIO_ASCLIN1_TX)
{
    IfxAsclin_Spi_isrTransmit(&g_asclinSpi);
}

IFX_INTERRUPT(asclin1RxISR, 0, IFX_INTPRIO_ASCLIN1_RX)
{
    IfxAsclin_Spi_isrReceive(&g_asclinSpi);
}

IFX_INTERRUPT(asclin1ErISR, 0, IFX_INTPRIO_ASCLIN1_ER)
{
    IfxAsclin_Spi_isrError(&g_asclinSpi);
}
```

各 ISR 作用：

- TX ISR：清 TX FIFO fill level flag，然后继续往 TX FIFO 填数据。
- RX ISR：清 RX FIFO fill level flag，然后从 RX FIFO 取数据。
- ER ISR：读取并清除错误标志，如 frame error、RX FIFO overflow/underflow、TX FIFO overflow。

`IfxAsclin_Spi_initInterrupt()` 会根据优先级是否大于 0 来初始化并使能对应 SRC 中断。如果优先级为 0，则对应中断不会启用。

## 8. 传输接口

核心传输函数：

```c
IfxAsclin_Spi_Status IfxAsclin_Spi_exchange(
    IfxAsclin_Spi *asclin,
    void *src,
    void *dest,
    uint32 count
);
```

参数含义：

- `src`：发送缓冲区；如果为 `NULL_PTR`，驱动会发送全 1，用于只读。
- `dest`：接收缓冲区；如果为 `NULL_PTR`，驱动会 dummy read，用于只写。
- `count`：传输字节数；应是数据宽度的整数倍。

返回值：

- `IfxAsclin_Spi_Status_ok`：成功启动传输。
- `IfxAsclin_Spi_Status_busy`：驱动正在忙，上一次传输还没结束。
- `IfxAsclin_Spi_Status_unknown`：未知状态，通常用于异常兜底。

常见用法：

```c
while (IfxAsclin_Spi_getStatus(&g_asclinSpi) == IfxAsclin_Spi_Status_busy)
{
}

IfxAsclin_Spi_exchange(&g_asclinSpi, txBuffer, rxBuffer, length);

while (IfxAsclin_Spi_getStatus(&g_asclinSpi) == IfxAsclin_Spi_Status_busy)
{
}
```

只发送：

```c
IfxAsclin_Spi_exchange(&g_asclinSpi, txBuffer, NULL_PTR, length);
```

只接收：

```c
IfxAsclin_Spi_exchange(&g_asclinSpi, NULL_PTR, rxBuffer, length);
```

## 9. 驱动内部传输机制

`IfxAsclin_Spi_exchange()` 做的事情：

1. 调用内部 lock，检查 `sending` 是否为 0。
2. 如果空闲，将 `sending` 设置为 1。
3. 设置 `transferInProgress = 1`。
4. 设置 TX job 和 RX job 的 buffer 指针。
5. 根据 `dataWidth` 把字节数转换成 8/16 bit 传输单元数。
6. 先调用 `IfxAsclin_Spi_write()` 往 TX FIFO 填一批数据。
7. 后续 TX/RX 中断继续完成剩余数据。
8. RX job 完成后，清 `transferInProgress`，并 unlock。

`IfxAsclin_Spi_write()` 重点：

- 根据 TX FIFO 剩余空间填入数据。
- 8 bit 模式调用 `IfxAsclin_write8()`。
- 16 bit 模式调用 `IfxAsclin_write16()`。
- 如果 `src == NULL_PTR`，写入 `~0`，也就是全 1。

`IfxAsclin_Spi_read()` 重点：

- 根据 RX FIFO fill level 读取数据。
- 8 bit 模式调用 `IfxAsclin_read8()`。
- 16 bit 模式调用 `IfxAsclin_read16()`。
- 如果 `dest == NULL_PTR`，执行 dummy read。
- RX pending 归零后判定本次 exchange 完成。

## 10. SPI 模式相关配置

SPI 从设备通常会要求 mode 0/1/2/3。ASCLIN SPI 中最相关的是：

- `inputOutput.cpol`：时钟空闲电平。
- `frame.shiftDir`：MSB/LSB first。
- `frame.leadDelay`：片选到时钟的 lead delay。
- `frame.stopBit`：可理解为 trailing delay。
- `inputOutput.spol`：片选空闲极性。

当前 iLLD ASCLIN SPI 配置里没有像 QSPI 那样直接叫 CPHA 的字段，需要结合 ASCLIN User Manual 的 FRAMECON/IOCR 时序定义确认从设备所需相位。写项目驱动时，建议把应用层配置抽象成 `mode`，再在底层集中映射。

## 11. 引脚选择注意点

ASCLIN SPI 引脚必须来自同一个 ASCLIN 模块，例如 ASCLIN1 的 SCLK、RX、TX、SLSO 应匹配到 ASCLIN1。

以 iLLD 示例为例：

- SCLK：`IfxAsclin1_SCLK_P15_0_OUT`
- RX：`IfxAsclin1_RXA_P15_1_IN`
- TX：`IfxAsclin1_TX_P15_4_OUT`
- SLSO：`IfxAsclin1_SLSO_P20_8_OUT`

RX 有 A/B/C/D/E/F/G 等不同输入复用项。配置 RX pin 后，还要保证：

```c
spiConfig.inputOutput.alti = pins.rx->select;
```

如果忘记设置或默认值与所选 RX pin 不一致，就可能出现 SCLK/TX 有波形但 RX 永远读不到数据。

## 12. 最小初始化模板

下面是一个可作为 BSW 封装起点的结构。实际引脚和优先级需要按项目调整。

```c
#include "Ifx_Types.h"
#include "IfxCpu_Irq.h"
#include "Asclin/Spi/IfxAsclin_Spi.h"

#define IFX_INTPRIO_ASCLIN1_TX  10
#define IFX_INTPRIO_ASCLIN1_RX  11
#define IFX_INTPRIO_ASCLIN1_ER  12

static IfxAsclin_Spi g_asclinSpi;

IFX_INTERRUPT(asclin1TxISR, 0, IFX_INTPRIO_ASCLIN1_TX)
{
    IfxAsclin_Spi_isrTransmit(&g_asclinSpi);
}

IFX_INTERRUPT(asclin1RxISR, 0, IFX_INTPRIO_ASCLIN1_RX)
{
    IfxAsclin_Spi_isrReceive(&g_asclinSpi);
}

IFX_INTERRUPT(asclin1ErISR, 0, IFX_INTPRIO_ASCLIN1_ER)
{
    IfxAsclin_Spi_isrError(&g_asclinSpi);
}

void BSW_ASCLIN_SPI_Init(void)
{
    IfxAsclin_Spi_Config config;

    IfxAsclin_Spi_initModuleConfig(&config, &MODULE_ASCLIN1);

    config.baudrate.prescaler = 1;
    config.baudrate.baudrate = 1000000.0f;
    config.dataLength = IfxAsclin_DataLength_8;
    config.frame.shiftDir = IfxAsclin_ShiftDirection_msbFirst;

    config.interrupt.txPriority = IFX_INTPRIO_ASCLIN1_TX;
    config.interrupt.rxPriority = IFX_INTPRIO_ASCLIN1_RX;
    config.interrupt.erPriority = IFX_INTPRIO_ASCLIN1_ER;
    config.interrupt.typeOfService = IfxCpu_Irq_getTos(IfxCpu_getCoreIndex());

    static const IfxAsclin_Spi_Pins pins = {
        &IfxAsclin1_SCLK_P15_0_OUT, IfxPort_OutputMode_pushPull,
        &IfxAsclin1_RXA_P15_1_IN,   IfxPort_InputMode_pullUp,
        &IfxAsclin1_TX_P15_4_OUT,   IfxPort_OutputMode_pushPull,
        &IfxAsclin1_SLSO_P20_8_OUT, IfxPort_OutputMode_pushPull,
        IfxPort_PadDriver_cmosAutomotiveSpeed1
    };

    config.inputOutput.alti = pins.rx->select;
    config.pins = &pins;

    (void)IfxAsclin_Spi_initModule(&g_asclinSpi, &config);
}

boolean BSW_ASCLIN_SPI_Exchange(const uint8 *tx, uint8 *rx, uint32 length)
{
    if (IfxAsclin_Spi_getStatus(&g_asclinSpi) == IfxAsclin_Spi_Status_busy)
    {
        return FALSE;
    }

    if (IfxAsclin_Spi_exchange(&g_asclinSpi, (void *)tx, rx, length) != IfxAsclin_Spi_Status_ok)
    {
        return FALSE;
    }

    while (IfxAsclin_Spi_getStatus(&g_asclinSpi) == IfxAsclin_Spi_Status_busy)
    {
    }

    return TRUE;
}
```

## 13. 调试检查清单

调试 ASCLIN SPI 时建议按这个顺序排查：

1. 确认使用的 ASCLIN 模块和四个 pin 都属于同一个 ASCLIN。
2. 确认 `config.inputOutput.alti = pins.rx->select`。
3. 确认 TX/RX/ER 中断优先级不为 0。
4. 确认 ISR 已经被编译进工程，且 vector provider 与运行 CPU 匹配。
5. 确认全局中断已使能。
6. 确认 SCLK 引脚有波形。
7. 确认 SLSO 极性是否符合从设备要求。
8. 确认 CPOL、数据位宽、MSB/LSB first 是否符合从设备要求。
9. 确认 `length` 是数据宽度的整数倍。
10. 如果只读，确认从设备是否需要先写命令再读数据。
11. 检查 `g_asclinSpi.errorFlags` 中是否有 frame error 或 FIFO overflow/underflow。

## 14. 后续封装建议

建议后续新增一层项目级 API，避免应用层直接依赖 iLLD 细节：

```c
void BSW_ASCLIN_SPI_Init(void);
boolean BSW_ASCLIN_SPI_Exchange(const uint8 *tx, uint8 *rx, uint32 length);
boolean BSW_ASCLIN_SPI_Write(const uint8 *tx, uint32 length);
boolean BSW_ASCLIN_SPI_Read(uint8 *rx, uint32 length);
boolean BSW_ASCLIN_SPI_IsBusy(void);
void BSW_ASCLIN_SPI_GetErrorFlags(IfxAsclin_Spi_ErrorFlags *flags);
```

如果后续同一工程既使用 QSPI 又使用 ASCLIN SPI，可以设计一个统一 SPI 抽象层：

```c
typedef enum
{
    BSW_SPI_BACKEND_QSPI,
    BSW_SPI_BACKEND_ASCLIN
} BSW_SPI_Backend;
```

这样应用层只关心“哪个 SPI 通道、哪个从设备、收发多少字节”，底层再决定是 QSPI 还是 ASCLIN SPI。

