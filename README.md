# kubeconfig-gen

一键为 Kubernetes 集群生成用户 kubeconfig 文件并配置 RBAC 权限。

基于 ServiceAccount Token 认证，自动完成：创建 ServiceAccount → 配置 RBAC → 生成 kubeconfig。

## 前置要求

- `kubectl` 已安装且可访问目标集群
- 当前 kubeconfig 拥有集群管理员权限

## 快速开始

```bash
# 命名空间级只读用户
./kubeconfig-gen.sh -u alice -n default -r readonly

# 使用生成的 kubeconfig
export KUBECONFIG=alice-kubeconfig
kubectl get pods
```

## 用法

```
./kubeconfig-gen.sh -u <username> [-n <ns1>,<ns2>,...] {-r <role> | -c <yaml>} [-o <output>] [-d <duration>]
./kubeconfig-gen.sh -u <username> --clean [-n <ns1>,<ns2>,...]
```

| 参数 | 说明 |
|------|------|
| `-u` | 用户名，即 ServiceAccount 名称（必选） |
| `-r` | 预设角色：`readonly` / `developer` / `operator` / `admin` / `cicd-runner` |
| `-c` | 自定义 RBAC YAML 文件路径 |
| `-n` | 命名空间，逗号分隔支持多个，省略则为集群级别权限 |
| `-o` | 输出文件路径，默认 `<username>-kubeconfig` |
| `-d` | Token 有效期，默认 `8760h`（1 年） |
| `--clean` | 清理该用户的 SA 和 RBAC 资源 |

`-r` 和 `-c` 二选一，不可同时使用。

## 预设角色

### readonly — 只读

查看核心资源，不可修改。

| API Groups | Resources | Verbs |
|------------|-----------|-------|
| `""` | pods, services, configmaps, secrets, pvc, namespaces, nodes, events 等 | get, list, watch |
| `apps` | deployments, daemonsets, statefulsets, replicasets | get, list, watch |
| `batch` | jobs, cronjobs | get, list, watch |
| `networking.k8s.io` | ingresses, networkpolicies | get, list, watch |
| `autoscaling` | hpa | get, list, watch |

### developer — 开发者

应用工作负载完整读写，基础设施资源只读。

在 readonly 基础上增加：
- pods/exec, pods/portforward 完整权限
- deployments, services, configmaps, secrets, ingresses 等 CRUD
- namespaces, nodes 仍为只读

### operator — 运维

开发权限 + 基础设施工作负载管理 + 节点/PV 只读。

在 developer 基础上增加：
- daemonsets, controllerrevisions CRUD
- serviceaccounts CRUD
- poddisruptionbudgets CRUD
- nodes, persistentvolumes 只读
- roles, rolebindings 只读

### admin — 管理员

作用域内全部权限（`*.*` 上 `*` verbs）。

命名空间级为 namespace admin，集群级为 cluster admin。

### cicd-runner — CI/CD 流水线

最小权限，仅支持更新镜像和查看部署状态。适合 GitLab Runner、GitHub Actions 等 CI/CD 场景。

| 资源 | 权限 | 用途 |
|------|------|------|
| deployments | get, list, watch, patch, update | 更新镜像、rollout restart |
| replicasets | get, list, watch | 查看 rollout 状态 |
| pods, pods/log | get, list, watch | 排查部署问题 |
| configmaps | get, list | 读取配置 |

不能 delete/create 资源，只能 patch/update 已有的 Deployment。

## 示例

### 多命名空间权限

`-n` 支持逗号分隔，为同一个用户在多个命名空间创建 Role + RoleBinding（不产生 ClusterRole）：

```bash
# CI/CD Runner 在 dev 和 stg1 都有更新镜像权限
./kubeconfig-gen.sh -u gitlab-runner -n dev,stg1 -r cicd-runner

# 开发者在多个环境有权限
./kubeconfig-gen.sh -u dev-user -n dev,stg1 -r developer

# 清理时使用相同的 -n 参数
./kubeconfig-gen.sh -u gitlab-runner -n dev,stg1 --clean
```

### 单命名空间权限

```bash
# 开发者，限定在 app-prod 命名空间
./kubeconfig-gen.sh -u dev-user -n app-prod -r developer

# 运维，限定在 monitoring 命名空间
./kubeconfig-gen.sh -u ops-sre -n monitoring -r operator
```

### 集群级权限

```bash
# 集群只读（可查看所有命名空间资源）
./kubeconfig-gen.sh -u viewer -r readonly

# 集群管理员
./kubeconfig-gen.sh -u cluster-admin -r admin
```

### 自定义 RBAC

```bash
# 使用自定义 YAML
./kubeconfig-gen.sh -u cicd-bot -n cicd-ns -c examples/custom-role.yaml
```

自定义 YAML 会被直接 `kubectl apply`，需自行确保 ServiceAccount 名称与 `-u` 参数一致。参考 [examples/custom-role.yaml](examples/custom-role.yaml)。

### Token 有效期

```bash
# 短期 token（1 小时，适合临时调试）
./kubeconfig-gen.sh -u temp-user -n default -r readonly -d 1h

# 长期 token（10 年，适合 CI/CD 服务账号）
./kubeconfig-gen.sh -u ci-pipeline -n ci -r developer -d 87600h
```

### 清理

```bash
# 删除用户的所有资源（SA、Role/ClusterRole、RoleBinding/ClusterRoleBinding）
./kubeconfig-gen.sh -u alice -n default --clean
./kubeconfig-gen.sh -u gitlab-runner -n dev,stg1 --clean
```

## 工作原理

1. **创建 ServiceAccount** — 在第一个目标 namespace 下创建 SA
2. **配置 RBAC** — 在每个指定 namespace 创建 Role + RoleBinding（省略 -n 则创建 ClusterRole + ClusterRoleBinding）
3. **获取 Token** — 优先使用 `kubectl create token`（k8s 1.24+），回退到创建 Secret
4. **生成 kubeconfig** — 从当前 context 提取集群 CA 和 API Server 地址，组装配置文件

## 目录结构

```
├── kubeconfig-gen.sh       # 主脚本
├── templates/              # 预设角色模板
│   ├── readonly.yaml
│   ├── developer.yaml
│   ├── operator.yaml
│   ├── admin.yaml
│   └── cicd-runner.yaml
└── examples/               # 自定义角色示例
    └── custom-role.yaml
```

## 注意事项

- 生成的 kubeconfig 文件权限为 `600`，包含集群访问 token，请妥善保管
- 多命名空间时，ServiceAccount 创建在第一个 namespace 下，其余 namespace 通过 RoleBinding 引用该 SA
- Token 过期后需重新生成，可使用 `--clean` 清理后重新创建
