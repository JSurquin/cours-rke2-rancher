# TP RKE2 + Rancher sur openSUSE Leap 16

Un PC sans machine virtuelle est un seul nœud Kubernetes. Les deux scripts installent RKE2 et Rancher (1 replica).

Prévoir Internet, 8 Go de RAM et 15 Go libres. L'installation dure souvent 15 à 40 minutes.

## RKE2, Rancher et une application en 2 pods

```bash
curl -fsSL -o install-rke2-rancher.sh https://raw.githubusercontent.com/JSurquin/cours-rke2-rancher/main/install-rke2-rancher.sh
sudo bash install-rke2-rancher.sh
```

L'application répond ensuite sur `http://127.0.0.1:30080/`.

## RKE2 et Rancher uniquement

```bash
curl -fsSL -o install-rke2-rancher-seul.sh https://raw.githubusercontent.com/JSurquin/cours-rke2-rancher/main/install-rke2-rancher-seul.sh
sudo bash install-rke2-rancher-seul.sh
```

Cette version ne crée pas d'application.

Premier accès Rancher : utilisateur `admin`, mot de passe `Cours-Rancher-2026`. Le certificat est auto-signé. Rancher demande ensuite un nouveau mot de passe d'au moins 12 caractères.

Pour retirer l'installation et restaurer firewalld, le swap et SELinux si le script les avait modifiés, relancer le même script avec `--desinstaller`.
