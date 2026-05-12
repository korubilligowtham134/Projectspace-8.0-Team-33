# 🔗 AI-Driven 2D Mesh Network-on-Chip (NoC)

> An advanced AI-enhanced Network-on-Chip architecture designed in SystemVerilog for next-generation many-core SoCs — integrating lightweight AI-based routing intelligence to reduce congestion, improve latency, and maximize throughput.


## 📖 Table of Contents

- [Project Overview](#-project-overview)
- [Key Features](#-key-features)
- [Architecture](#-architecture)
- [Tech Stack](#-tech-stack)
- [Performance Results](#-performance-results)
- [Getting Started](#-getting-started)
- [Usage](#-usage)
- [Project Structure](#-project-structure)
- [Configuration](#-configuration)
- [Roadmap](#-roadmap)
- [Contributing](#-contributing)
- [License](#-license)

---

## 🚀 Project Overview

Modern System-on-Chip (SoC) architectures face major communication bottlenecks as the number of processor cores scales up. Traditional routing strategies such as **XY Routing** and **Round-Robin Arbitration** are static and reactive — causing:

- ❌ High packet latency
- ❌ Congestion hotspots
- ❌ Reduced throughput
- ❌ Poor scalability in AI/ML workloads

This project introduces an **AI-Driven 2D Mesh NoC** that leverages:

- ✅ **Predictive congestion estimation**
- ✅ **AI-based arbitration**
- ✅ **Adaptive routing decisions**
- ✅ **Deterministic deadlock-free safety control**

The result is a **self-optimizing NoC microarchitecture** capable of reducing average packet latency by up to **~46%** compared to traditional designs.

---

## ✨ Key Features

### 🧠 AI-Based Neural Arbiter

Traditional arbiters are replaced with a **lightweight hardware AI inference engine** that calculates routing scores dynamically using:

| Input Factor       | Description                                          |
|--------------------|------------------------------------------------------|
| Buffer Occupancy   | Current fill level of input buffers per port         |
| Packet Priority    | Priority class assigned to each packet               |
| Congestion Status  | Real-time congestion flag from neighboring routers   |
| Traffic History    | Short-term trend of past traffic on each link        |

The Neural Arbiter performs **predictive path selection** rather than simple round-robin allocation, enabling smarter and faster routing decisions at runtime.

---

### 📈 Predictive Congestion Control

The router continuously monitors neighboring traffic behavior and **predicts congestion before it occurs**, including:

- Congestion history tracking per port
- Traffic trend analysis
- **30-cycle predictive lookahead**
- Hotspot avoidance via preemptive rerouting

This shifts routing from a *reactive* approach to a *predictive adaptive* system — significantly reducing stall cycles and improving overall network utilization.

---

### 🔒 Deadlock-Free Deterministic Safety

All AI-driven routing decisions are governed by a deterministic safety layer that enforces:

- Turn model restrictions to prevent routing cycles
- Virtual channel (VC) assignment rules
- Fallback to safe XY routing if AI confidence is below threshold

This ensures **functional correctness** is never compromised by adaptive routing.

---

## 🏗 Architecture

The NoC uses a **2D Mesh Topology** where each node is a fully featured router with AI-enhanced decision-making.

```
┌────────┐     ┌────────┐     ┌────────┐
│Router00│────▶│Router01│────▶│Router02│
│  (PE)  │     │  (PE)  │     │  (PE)  │
└────┬───┘     └────┬───┘     └────┬───┘
     │              │              │
     ▼              ▼              ▼
┌────────┐     ┌────────┐     ┌────────┐
│Router10│────▶│Router11│────▶│Router12│
│  (PE)  │     │  (PE)  │     │  (PE)  │
└────────┘     └────────┘     └────────┘
```

### Router Internals

Each router contains the following components:

```
┌─────────────────────────────────────────┐
│                  Router                 │
│                                         │
│  ┌──────────┐     ┌───────────────────┐ │
│  │  Input   │────▶│  Neural Arbiter   │ │
│  │ Buffers  │     │  (AI Inference)   │ │
│  └──────────┘     └────────┬──────────┘ │
│                            │            │
│  ┌──────────┐     ┌────────▼──────────┐ │
│  │Congestion│────▶│  Crossbar Switch  │ │
│  │Predictor │     │   (Switch Alloc)  │ │
│  └──────────┘     └───────────────────┘ │
│                                         │
│  ┌──────────────────────────────────┐   │
│  │     Virtual Channel Manager      │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

**Key Modules:**

- `neural_arbiter.sv` — AI-based port arbitration and routing score computation
- `congestion_predictor.sv` — 30-cycle lookahead congestion estimator
- `crossbar_switch.sv` — Non-blocking switch with AI-guided allocation
- `vc_manager.sv` — Virtual channel allocation and flow control
- `router_top.sv` — Top-level router integrating all submodules
- `noc_top.sv` — 2D mesh instantiation and inter-router wiring

---

## 🛠 Tech Stack

| Category            | Tool / Language                     |
|---------------------|-------------------------------------|
| RTL Design          | SystemVerilog                       |
| Simulation          | Cadence Xcelium                     |
| Design Target       | ASIC-Oriented RTL                   |
| AI/ML Concepts      | Lightweight Neural Inference Engine |
| Analysis & Training | Python 3.x                          |
| Dataset Generation  | CSV-based traffic pattern generator |

---

## 📊 Performance Results

Simulation results comparing **Traditional XY Routing** vs. the **AI-Enhanced NoC** on identical traffic workloads:

| Metric                | Traditional XY Routing  | AI-Enhanced NoC         | Improvement       |
|-----------------------|-------------------------|-------------------------|-------------------|
| Packets Transferred   | 51                      | 51                      | —                 |
| **Average Latency**   | 65.49 ns                | **35.49 ns**            | ✅ ~46% reduction |
| Throughput            | 0.020319 packets/ns     | 0.020319 packets/ns     | —                 |
| Congestion Events     | High (hotspot-prone)    | Low (predictive bypass) | ✅ Significant    |
| Deadlock Incidents    | 0                       | 0                       | ✅ Safe           |

> ⚠️ Throughput remains equivalent because the same number of packets was injected. The key improvement is the dramatic reduction in **latency**, directly translating to faster core-to-core communication.

---

## ⚙️ Getting Started

### Prerequisites

Ensure the following are installed and accessible:

- **Cadence Xcelium** (for SystemVerilog simulation)
- **Python 3.8+** (for dataset generation and result analysis)
- `pip install pandas matplotlib numpy`

### Clone the Repository

```bash
git clone https://github.com/your-username/ai-driven-noc.git
cd ai-driven-noc
```

### Run Simulation

```bash
# Compile the design
xrun -sv src/*.sv tb/tb_noc_top.sv -top tb_noc_top

# Or use the provided Makefile
make sim
```

### Generate Traffic Dataset

```bash
cd scripts/
python generate_traffic.py --nodes 9 --packets 100 --output traffic.csv
```

---

## 🧪 Usage

### Running the Testbench

```bash
# Run full regression
make run_all

# Run a specific test case
xrun -sv src/*.sv tb/tb_router.sv -top tb_router +define+TEST_CONGESTION

# Dump waveforms
xrun -sv src/*.sv tb/tb_noc_top.sv -top tb_noc_top -access +rwc -input wave.tcl
```

### Analyzing Results

```bash
cd scripts/
python analyze_results.py --input ../sim/output/latency_log.csv --plot
```

This generates latency distribution plots, throughput curves, and congestion heatmaps.

---

## 📁 Project Structure

```
ai-driven-noc/
│
├── src/                        # RTL Source Files
│   ├── noc_top.sv              # Top-level 2D Mesh NoC
│   ├── router_top.sv           # Router top-level
│   ├── neural_arbiter.sv       # AI Neural Arbiter
│   ├── congestion_predictor.sv # Predictive congestion module
│   ├── crossbar_switch.sv      # Crossbar with AI allocation
│   ├── vc_manager.sv           # Virtual channel manager
│   └── input_buffer.sv         # Input FIFO buffers
│
├── tb/                         # Testbenches
│   ├── tb_noc_top.sv           # Full NoC testbench
│   ├── tb_router.sv            # Router-level testbench
│   └── tb_neural_arbiter.sv    # Arbiter unit test
│
├── scripts/                    # Python Utilities
│   ├── generate_traffic.py     # CSV traffic dataset generator
│   ├── analyze_results.py      # Performance analysis & plots
│   └── train_model.py          # AI weight training (offline)
│
├── sim/                        # Simulation outputs
│   └── output/
│
├── docs/                       # Documentation & reports
│
├── Makefile                    # Build automation
└── README.md
```

---

## 🔧 Configuration

Key parameters configurable via SystemVerilog `parameter` definitions in `noc_top.sv`:

| Parameter         | Default | Description                              |
|-------------------|---------|------------------------------------------|
| `MESH_SIZE`       | `3`     | Dimension of the 2D mesh (NxN)           |
| `VC_COUNT`        | `4`     | Number of virtual channels per port      |
| `BUFFER_DEPTH`    | `8`     | Input buffer FIFO depth (in flits)       |
| `PREDICT_WINDOW`  | `30`    | Congestion prediction lookahead (cycles) |
| `AI_THRESHOLD`    | `0.75`  | Minimum AI confidence for adaptive route |
| `FLIT_WIDTH`      | `32`    | Data flit width in bits                  |







<p align="center">
  <i>Built with ❤️ for next-generation SoC design</i>
</p>
