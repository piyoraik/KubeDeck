#!/bin/sh
# kind に検証用のものを置く／片付ける。**kind 専用**（GKE では絶対に走らせない）。
#   kind-fixtures.sh up    CRD と、何も読めない ServiceAccount を作る
#   kind-fixtures.sh down  片付ける
set -e
cd "$(dirname "$0")"
CTX=kind-kubedeck
K="kubectl --context $CTX"

case "${1:-}" in
up)
  $K apply -f - <<'YAML'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.kubedeck.test
spec:
  group: kubedeck.test
  names:
    kind: Widget
    listKind: WidgetList
    plural: widgets
    singular: widget
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                size: {type: string}
      additionalPrinterColumns:
        - name: Size
          type: string
          jsonPath: .spec.size
YAML
  $K wait --for=condition=Established crd/widgets.kubedeck.test --timeout=60s
  for n in one two three; do
    $K apply -f - <<YAML
apiVersion: kubedeck.test/v1alpha1
kind: Widget
metadata:
  name: $n
  namespace: default
spec:
  size: "$n"
YAML
  done

  # 何も読めない ServiceAccount と、そのトークンを使う kubeconfig
  $K create serviceaccount kubedeck-nobody -n default --dry-run=client -o yaml | $K apply -f -
  TOKEN=$($K create token kubedeck-nobody -n default --duration=3600s)
  SERVER=$($K config view --raw -o jsonpath="{.clusters[?(@.name==\"kind-kubedeck\")].cluster.server}")
  CA=$($K config view --raw -o jsonpath="{.clusters[?(@.name==\"kind-kubedeck\")].cluster.certificate-authority-data}")
  # **作った瞬間から 0600 にする。** あとから `chmod` すると、書いてから
  # 直すまでのあいだ 0644 で存在する —— 中身は ServiceAccount のトークンで、
  # `.gitignore` に足してまで「絶対にコミットしない」と決めた当のもの。
  (umask 077; cat > nobody.kubeconfig <<YAML
apiVersion: v1
kind: Config
clusters:
- name: kind-kubedeck
  cluster:
    server: $SERVER
    certificate-authority-data: $CA
contexts:
- name: kind-kubedeck
  context: {cluster: kind-kubedeck, user: nobody}
users:
- name: nobody
  user: {token: $TOKEN}
current-context: kind-kubedeck
YAML
  )
  chmod 600 nobody.kubeconfig 2>/dev/null || true
  echo "置いた: CRD widgets.kubedeck.test（Widget 3 件）/ nobody.kubeconfig"
  ;;
down)
  $K delete crd widgets.kubedeck.test --ignore-not-found=true --wait=false
  $K delete serviceaccount kubedeck-nobody -n default --ignore-not-found=true
  rm -f nobody.kubeconfig
  echo "片付けた"
  ;;
*)
  echo "usage: kind-fixtures.sh up|down" >&2; exit 2;;
esac
