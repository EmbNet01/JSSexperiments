from pathlib import Path

import pandas as pd


EXATHLON_FEATURES = {
    "exathlon1": [
        "X1_jvm_pools_PS.Eden.Space_max_value",
        "X1_jvm_pools_PS.Survivor.Space_committed_value",
        "X2_jvm_heap_committed_value",
        "driver_BlockManager_memory_memUsed_MB_value",
        "driver_BlockManager_memory_remainingMem_MB_value",
        "node5_NET_ib0.write.KB.s",
        "node6_CPU031_User.",
        "node6_NETPACKET_em1.write.s",
        "node6_NET_ib0.write.KB.s",
        "node7_NET_ib0.read.KB.s",
    ],
    "exathlon2": [
        "X1_jvm_pools_PS.Eden.Space_max_value",
        "X1_jvm_pools_PS.Survivor.Space_committed_value",
        "X2_jvm_heap_committed_value",
        "driver_BlockManager_memory_memUsed_MB_value",
        "driver_BlockManager_memory_remainingMem_MB_value",
        "driver_DAGScheduler_stage_waitingStages_value",
        "node5_NET_ib0.write.KB.s",
        "node6_CPU031_User.",
        "node6_NETPACKET_em1.write.s",
        "node6_NET_ib0.write.KB.s",
        "node7_NET_ib0.read.KB.s",
    ],
    "exathlon3": [
        "X2_jvm_heap_committed_value",
        "X2_jvm_heap_usage_value",
        "X2_jvm_pools_PS.Eden.Space_committed_value",
        "X2_jvm_pools_PS.Old.Gen_usage_value",
        "driver_BlockManager_memory_memUsed_MB_value",
        "node5_CPU023_User.",
        "node5_NETPACKET_em1.read.s",
        "node5_NET_ib0.read.KB.s",
        "node5_NET_ib0.write.KB.s",
        "node6_NET_ib0.read.KB.s",
        "node7_NET_ib0.write.KB.s",
        "node8_CPU009_User.",
        "node8_CPU015_User.",
        "node8_NETPACKET_em1.write.s",
    ],
}

MATERNA_FEATURES = [
    "CPU.usage..MHZ.",
    "Memory.usage..KB.",
    "Disk.write.throughput..KB.s.",
    "Network.received.throughput..KB.s.",
    "Network.transmitted.throughput..KB.s.",
]

POD_METRICS_FEATURES = [
    "adservice-cpu",
    "cartservice-cpu",
    "checkoutservice-cpu",
    "currencyservice-cpu",
    "emailservice-cpu",
    "frontend-cpu",
    "paymentservice-cpu",
    "productcatalogservice-cpu",
    "recommendationservice-cpu",
    "redis-cart-cpu",
    "shippingservice-cpu",
    "adservice-mem",
    "cartservice-mem",
    "checkoutservice-mem",
    "currencyservice-mem",
    "emailservice-mem",
    "frontend-mem",
    "paymentservice-mem",
    "productcatalogservice-mem",
    "recommendationservice-mem",
    "redis-cart-mem",
    "shippingservice-mem",
]


def load_dataset(dataset: str, project_root: Path):
    dataset = dataset.lower()
    data_dir = project_root / "datasets"

    if dataset in EXATHLON_FEATURES:
        data_number = dataset.replace("exathlon", "")
        df = pd.read_csv(data_dir / f"Exathlon_Data{data_number}.csv")
        features = EXATHLON_FEATURES[dataset]
        split = int(len(df) * 0.7)
        return df.iloc[:split].reset_index(drop=True), df.iloc[split:].reset_index(drop=True), features

    if dataset == "materna":
        df = pd.read_csv(data_dir / "Materna.csv")
        split = int(len(df) * 0.7)
        return df.iloc[:split].reset_index(drop=True), df.iloc[split:].reset_index(drop=True), MATERNA_FEATURES

    if dataset in {"pod_metrics", "kubernetes"}:
        return (
            pd.read_csv(data_dir / "pod_metrics_train.csv").reset_index(drop=True),
            pd.read_csv(data_dir / "pod_metrics_test.csv").reset_index(drop=True),
            POD_METRICS_FEATURES,
        )

    valid = ["exathlon1", "exathlon2", "exathlon3", "materna", "pod_metrics", "kubernetes"]
    raise ValueError(f"Unsupported dataset {dataset!r}. Valid values: {valid}")
