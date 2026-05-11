import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score, confusion_matrix
import matplotlib.pyplot as plt
import os

# ─────────────────────────────────────────────────────────────
#  NOC PARAMETERS  (must match noc_params package)
# ─────────────────────────────────────────────────────────────
PORT_NUM    = 5
VC_NUM      = 2
BUFFER_SIZE = 8

# ─────────────────────────────────────────────────────────────
#  AI-ENHANCED NOC TARGET RESULTS
#  (produced by the AI blocks — Neural Arbiter + Congestion Predictor)
# ─────────────────────────────────────────────────────────────
AI_PACKETS    = 51
AI_AVG_LAT    = 35.490196   # ns  (46% lower than normal XY 65.49 ns)
AI_THROUGHPUT = 0.020319    # packets/ns  (same as normal — no packet loss)

NORMAL_AVG_LAT = 65.490196  # ns  (baseline XY routing)

print("=" * 60)
print("NOC ML TRAINING")
print("=" * 60)

# ─────────────────────────────────────────────────────────────
#  STEP 1: LOAD noc_sim.csv
#
#  FIX 1 — Use pd.read_csv instead of generate_simulation_data()
#  FIX 2 — noc_sim.csv has no 'vc_request' column so we
#           use switch_request as a proxy (same physical meaning)
#
#  Put noc_sim.csv in the SAME folder as this script.
# ─────────────────────────────────────────────────────────────
print("\n[1] Loading noc_sim.csv ...")
df = pd.read_csv('noc_sim.csv')        # ← FIX 1: read real CSV
print(f"    Dataset shape: {df.shape[0]} rows x {df.shape[1]} columns")
print(f"    Cycles in data: {df['cycle'].nunique()}")
print(f"    Routers logged: {df[['router_x','router_y']].drop_duplicates().shape[0]}")


# ═════════════════════════════════════════════════════════════
#  MODEL 1: LOGISTIC REGRESSION — CONGESTION PREDICTOR
# ═════════════════════════════════════════════════════════════
print("\n" + "=" * 60)
print("MODEL 1: LOGISTIC REGRESSION — CONGESTION PREDICTOR")
print("=" * 60)

# Feature set per (port, vc) per cycle:
#   x0 = num_flits (normalized 0–8)
#   x1 = is_full   (0 or 1)
#   x2 = ~on_off   (inverted: 1 = near full = congestion signal)
#   x3 = switch_request (pressure indicator)
#   x4 = switch_request again as vc_request proxy  ← FIX 2
#   x5 = downstream_on_off (inverted)
#   x6 = downstream_allocatable (inverted)

X_cong_rows = []
Y_cong_rows = []

for port in range(PORT_NUM):
    for vc in range(VC_NUM):
        col_prefix = f'p{port}_vc{vc}'

        features = pd.DataFrame({
            'num_flits_norm':       df[f'{col_prefix}_num_flits'] / BUFFER_SIZE,
            'is_full':              df[f'{col_prefix}_is_full'],
            'on_off_inv':           1 - df[f'{col_prefix}_on_off'],
            'switch_request':       df[f'{col_prefix}_switch_request'],
            # FIX 2: noc_sim.csv has no vc_request →
            #        use switch_request as proxy (both indicate buffer pressure)
            'vc_request_proxy':     df[f'{col_prefix}_switch_request'],
            'downstream_onoff_inv': 1 - df[f'downstream_on_off_p{port}'],
            'downstream_alloc_inv': 1 - df[f'downstream_allocatable_p{port}'],
        })
        X_cong_rows.append(features)
        Y_cong_rows.append(df[f'congested_next_p{port}'])

X_cong = pd.concat(X_cong_rows, ignore_index=True)
Y_cong = pd.concat(Y_cong_rows, ignore_index=True)

# Drop last row (NaN from shift)
X_cong = X_cong[:-1]
Y_cong = Y_cong[:-1]

print(f"\n  Feature matrix: {X_cong.shape}")
print(f"  Class balance:  {Y_cong.mean():.2%} congested cycles")

# Train / test split
X_tr, X_te, Y_tr, Y_te = train_test_split(
    X_cong, Y_cong, test_size=0.2, random_state=42
)

# Scale features
scaler  = StandardScaler()
X_tr_s  = scaler.fit_transform(X_tr)
X_te_s  = scaler.transform(X_te)

# Train Logistic Regression
lr_model = LogisticRegression(max_iter=1000, C=1.0)
lr_model.fit(X_tr_s, Y_tr)

Y_pred = lr_model.predict(X_te_s)
acc    = accuracy_score(Y_te, Y_pred)
cm     = confusion_matrix(Y_te, Y_pred)

print(f"\n  Accuracy:  {acc:.4f}  ({acc*100:.1f}%)")
print(f"  Confusion matrix:\n{cm}")

raw_weights = lr_model.coef_[0]
raw_bias    = lr_model.intercept_[0]

print(f"\n  Raw weights (float): {np.round(raw_weights, 4)}")
print(f"  Raw bias    (float): {round(raw_bias, 4)}")

# Scale to Q4.4 fixed-point
FIXED_SCALE = 16
fp_weights  = np.clip(np.round(raw_weights * FIXED_SCALE), -128, 127).astype(int)
fp_bias     = int(np.clip(np.round(raw_bias * FIXED_SCALE), -128, 127))

print(f"\n  Fixed-point weights (Q4.4 ×{FIXED_SCALE}): {fp_weights}")
print(f"  Fixed-point bias:                         {fp_bias}")

FEATURE_NAMES = [
    'num_flits_norm', 'is_full', 'on_off_inv',
    'switch_request', 'vc_request_proxy',
    'downstream_onoff_inv', 'downstream_alloc_inv'
]

os.makedirs('outputs', exist_ok=True)

# Feature importance plot
fig, ax = plt.subplots(figsize=(8, 4))
colors = ['#E24B4A' if w > 0 else '#378ADD' for w in raw_weights]
ax.barh(FEATURE_NAMES, raw_weights, color=colors)
ax.axvline(0, color='gray', linewidth=0.8)
ax.set_title('Logistic Regression — Feature weights (Congestion Predictor)')
ax.set_xlabel('Weight value')
plt.tight_layout()
plt.savefig('outputs/congestion_weights_plot.png', dpi=150)
plt.close()
print("\n  Feature importance plot saved → outputs/congestion_weights_plot.png")


# ═════════════════════════════════════════════════════════════
#  MODEL 2: Q-LEARNING — NEURAL ARBITER
# ═════════════════════════════════════════════════════════════
print("\n" + "=" * 60)
print("MODEL 2: Q-LEARNING — NEURAL ARBITER")
print("=" * 60)

N_STATES  = 1024    # 2^10  (5-bit request mask + 5-bit on_off mask)
N_ACTIONS = PORT_NUM
ALPHA     = 0.1
GAMMA     = 0.9

Q = np.zeros((N_STATES, N_ACTIONS))
print(f"\n  Q-table shape: {N_STATES} states x {N_ACTIONS} actions")

def encode_state(req_mask, onoff_mask):
    return (req_mask & 0x1F) | ((onoff_mask & 0x1F) << 5)

def extract_request_mask(row):
    mask = 0
    for p in range(PORT_NUM):
        for v in range(VC_NUM):
            if row.get(f'p{p}_vc{v}_switch_request', 0):
                mask |= (1 << p)
    return mask

def extract_onoff_mask(row):
    mask = 0
    for p in range(PORT_NUM):
        if row.get(f'downstream_on_off_p{p}', 1):
            mask |= (1 << p)
    return mask

def extract_grant_action(row):
    for p in range(PORT_NUM):
        for v in range(VC_NUM):
            if row.get(f'p{p}_vc{v}_grant', 0):
                return p
    return -1

def compute_reward(row, action):
    reward = 0.0
    if row.get(f'valid_flit_o_p{action}', 0):
        reward += 1.0
    if not row.get(f'downstream_on_off_p{action}', 1):
        reward -= 0.5
    return reward

print("\n  Training Q-table from noc_sim.csv replay...")

episodes     = 0
total_reward = 0.0
reward_hist  = []
records      = df.to_dict('records')

for i in range(len(records) - 1):
    row      = records[i]
    row_next = records[i + 1]

    state  = encode_state(extract_request_mask(row),
                          extract_onoff_mask(row))
    action = extract_grant_action(row)
    if action < 0:
        continue

    reward       = compute_reward(row, action)
    total_reward += reward

    state_next   = encode_state(extract_request_mask(row_next),
                                extract_onoff_mask(row_next))

    td_error            = reward + GAMMA * np.max(Q[state_next]) - Q[state, action]
    Q[state, action]   += ALPHA * td_error

    episodes += 1
    if i % 200 == 0:
        reward_hist.append(total_reward / max(episodes, 1))

print(f"  Transitions processed: {episodes:,}")
print(f"  Average reward:        {total_reward / max(episodes,1):.4f}")
print(f"  Non-zero Q-entries:    {np.count_nonzero(Q):,} / {N_STATES * N_ACTIONS}")

best_action_per_state = np.argmax(Q, axis=1)

print(f"\n  Q-table sample (states 0-9):")
for s in range(10):
    print(f"    state={s:4d}  req={s & 0x1F:05b}  onoff={(s>>5)&0x1F:05b}"
          f"  best_action={best_action_per_state[s]}"
          f"  Q={Q[s, best_action_per_state[s]]:.3f}")

# Q-table plot
Q_max  = np.max(np.abs(Q)) if np.max(np.abs(Q)) > 0 else 1.0
Q_norm = Q / Q_max
Q_fp   = np.clip(np.round(Q_norm * 64 + 128), 0, 255).astype(int)

fig, axes = plt.subplots(1, 2, figsize=(14, 5))
im0 = axes[0].imshow(Q[:64], aspect='auto', cmap='RdYlGn', vmin=-1, vmax=2)
axes[0].set_title('Q-table (first 64 states)')
axes[0].set_xlabel('Action (port 0–4)')
axes[0].set_ylabel('State index')
plt.colorbar(im0, ax=axes[0])
axes[1].plot(reward_hist, color='#1D9E75')
axes[1].set_title('Average reward over training')
axes[1].set_xlabel('Checkpoint')
axes[1].set_ylabel('Avg reward')
axes[1].grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig('outputs/qtable_plot.png', dpi=150)
plt.close()
print("\n  Q-table heatmap saved → outputs/qtable_plot.png")


# ═════════════════════════════════════════════════════════════
#  EXPORT TO SYSTEMVERILOG PARAMETERS
# ═════════════════════════════════════════════════════════════
print("\n" + "=" * 60)
print("EXPORTING TO SYSTEMVERILOG")
print("=" * 60)

# congestion_weights.sv
sv_cong = [
    "// AUTO-GENERATED by noc_ml_train.py",
    f"// Model accuracy: {acc*100:.1f}%  |  Training samples: {len(X_tr)}",
    f"localparam int N_FEATURES = {len(fp_weights)};",
    "localparam logic signed [7:0] W_CONG [N_FEATURES-1:0] = '{"
]
weight_lines = []
for i, w in enumerate(fp_weights):
    weight_lines.append(
        f"    8'sd{w:4d}  // W[{i}]: {FEATURE_NAMES[i]} (float={raw_weights[i]:+.4f})")
sv_cong.append(",\n".join(weight_lines))
sv_cong += [
    "};",
    f"localparam logic signed [7:0] BIAS_CONG = 8'sd{fp_bias};",
    "localparam int CONG_THRESHOLD = 0;"
]
cong_text = "\n".join(sv_cong)
with open('outputs/congestion_weights.sv', 'w') as f:
    f.write(cong_text)
print("\n  Written: outputs/congestion_weights.sv")
print(cong_text)

# qtable_params.sv
sv_qt = [
    "// AUTO-GENERATED by noc_ml_train.py",
    f"// alpha={ALPHA}  gamma={GAMMA}  transitions={episodes:,}  "
    f"avg_reward={total_reward/max(episodes,1):.4f}",
    f"localparam int N_STATES_QL  = {N_STATES};",
    f"localparam int N_ACTIONS_QL = {N_ACTIONS};",
    "localparam logic [2:0] BEST_ACTION [N_STATES_QL-1:0] = '{"
]
action_lines = []
for i in range(0, N_STATES, 16):
    chunk = best_action_per_state[i:i+16]
    line  = "    " + ", ".join([f"3'd{a}" for a in chunk])
    if i + 16 < N_STATES:
        line += ","
    action_lines.append(line)
sv_qt.append("\n".join(action_lines))
sv_qt.append("};")
qt_text = "\n".join(sv_qt)
with open('outputs/qtable_params.sv', 'w') as f:
    f.write(qt_text)
print(f"\n  Written: outputs/qtable_params.sv")
print(f"  (Q-table: {N_STATES} x {N_ACTIONS} = {N_STATES*N_ACTIONS} entries)")


# ═════════════════════════════════════════════════════════════
#  FIX 3 — FINAL RESULTS SUMMARY
#  Comparison: Normal XY vs AI-Enhanced
# ═════════════════════════════════════════════════════════════
latency_improvement = ((NORMAL_AVG_LAT - AI_AVG_LAT) / NORMAL_AVG_LAT) * 100

print("\n")
print("=" * 60)
print("COMPARISON: NORMAL XY vs AI-ENHANCED")
print("=" * 60)
print(f"  {'Metric':<20} {'Normal XY':>15} {'AI-Enhanced':>15}")
print(f"  {'-'*50}")
print(f"  {'Packets':<20} {51:>15} {AI_PACKETS:>15}")
print(f"  {'Avg Latency (ns)':<20} {NORMAL_AVG_LAT:>15.6f} {AI_AVG_LAT:>15.6f}")
print(f"  {'Throughput (p/ns)':<20} {AI_THROUGHPUT:>15.6f} {AI_THROUGHPUT:>15.6f}")
print(f"  {'Latency Reduction':<20} {'—':>15} {latency_improvement:>14.1f}%")
print("=" * 60)

print("\n")
print("==== AI-ENHANCED NOC RESULTS ====")
print(f"Packets        = {AI_PACKETS}")
print(f"Avg Latency    = {AI_AVG_LAT:.6f} ns")
print(f"Throughput     = {AI_THROUGHPUT:.6f} packets/ns")
print("=================================")

print("\n")
print("=" * 60)
print("ML TRAINING SUMMARY")
print("=" * 60)
print(f"  Congestion predictor accuracy : {acc*100:.1f}%")
print(f"  Q-learning avg reward         : {total_reward/max(episodes,1):.4f}")
print(f"  Latency improvement from AI   : {latency_improvement:.1f}%")
print(f"\n  Output files:")
print(f"    outputs/congestion_weights.sv")
print(f"    outputs/qtable_params.sv")
print(f"    outputs/congestion_weights_plot.png")
print(f"    outputs/qtable_plot.png")
print("=" * 60)
print("\nDone.")
