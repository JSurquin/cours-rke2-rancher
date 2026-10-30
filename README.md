# TP RKE2 + Rancher sur openSUSE Leap 16

Un PC sans machine virtuelle est un seul nœud Kubernetes. Le script installe RKE2, Rancher (1 replica) et une page de démonstration en 2 pods sur ce même nœud.

Prévoir Internet, 8 Go de RAM et 15 Go libres. L'installation dure souvent 15 à 40 minutes.

```bash
curl -fsSL -o install-rke2-rancher.sh https://raw.githubusercontent.com/JSurquin/cours-rke2-rancher/main/install-rke2-rancher.sh
sudo bash install-rke2-rancher.sh
```

Premier accès Rancher : utilisateur `admin`, mot de passe `Cours-Rancher-2026`. Le certificat est auto-signé. Rancher demande ensuite un nouveau mot de passe d'au moins 12 caractères.

Pour retirer l'installation et restaurer firewalld, le swap et SELinux si le script les avait modifiés :

```bash
sudo bash install-rke2-rancher.sh --desinstaller
```
