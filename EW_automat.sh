#!/usr/bin/env bash
# Easyweb Git Wizard — interactif, sûr, sans merge automatique
# Dépôt visé : https://github.com/easychief/easyweb.git
# - Validation vraie via Git (git check-ref-format --branch)
# - Nettoyage entrée (trim + suppression de \r cachés)
# - Rebase propre (jamais de merge auto)
# - Génère/actualise la PR (URL compare)
# - Vérifications finales strictes
set -euo pipefail
IFS=$'\n\t'

say()   { printf "\n\033[1m%s\033[0m\n" "$*"; }
info()  { printf "%s\n" "$*"; }
warn()  { printf "\033[33m%s\033[0m\n" "$*"; }
err()   { printf "\033[31m%s\033[0m\n" "$*"; }
sep()   { printf "\n------------------------------\n"; }

confirm() {
  local msg="${1:-Continuer ?}"; local def="${2:-y}"
  local hint="[y/N]"; [ "$def" = "y" ] && hint="[Y/n]"
  printf "%s %s " "$msg" "$hint"
  read -r ans || true
  ans="${ans:-$def}"
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

ask_non_empty() {
  local prompt="${1:-Valeur: }" var
  while true; do
    printf "%s" "$prompt"
    read -r var || true
    if [ -n "${var:-}" ]; then
      printf "%s" "$var"
      return 0
    fi
    err "Entrée vide, réessaye."
  done
}

run_cmd() {
  local cmd="$*"
  sep; say "Commande proposée :"; printf "%s\n" "$cmd"; sep
  if confirm "Exécuter cette commande ?" "y"; then
    bash -lc "$cmd"
    local rc=$?
    sep; info "Code retour: $rc"; sep
    return $rc
  else
    warn "Commande ignorée."
    return 0
  fi
}

ensure_git_repo() {
  if [ ! -d .git ]; then
    err "❌ Pas de dépôt Git ici. Place-toi à la racine du projet (.git)."
    exit 1
  fi
}

ensure_no_in_progress() {
  if [ -f .git/MERGE_HEAD ] || [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
    warn "⚠️ Un rebase/merge est en cours."
    if confirm "Abandonner ce rebase/merge ?" "y"; then
      run_cmd "git merge --abort 2>/dev/null || true"
      run_cmd "git rebase --abort 2>/dev/null || true"
    else
      err "Interrompu : termine d'abord ce rebase/merge."
      exit 1
    fi
  fi
}

validate_remote_origin() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  if [ -z "$remote_url" ]; then
    err "❌ Aucun remote 'origin' configuré."
    info "Ajoute-le, par ex. : git remote add origin https://github.com/easychief/easyweb.git"
    exit 1
  fi
  info "Remote origin: $remote_url"
}

check_clean_tree() {
  git diff --quiet && git diff --quiet --cached
}

assert_clean_tree_or_offer_fix() {
  say "Vérifier que l'arbre de travail est propre"
  if check_clean_tree; then
    info "✅ Arbre propre."
    return 0
  fi
  warn "⚠️ Modifications locales détectées."
  run_cmd "git status -sb"
  if confirm "Option A: Stasher TOUT (y compris non-suivis) ?" "y"; then
    run_cmd "git stash push -m 'wizard: WIP' --include-untracked"
  elif confirm "Option B: Restaurer TOUT (git restore -SW .) ?" "n"; then
    run_cmd "git restore -SW ."
  elif confirm "Option C: Commiter ces changements (déconseillé tout de suite) ?" "n"; then
    run_cmd "git add -A"
    printf "Message de commit (défaut 'chore: WIP'): "
    read -r msg || true
    msg="${msg:-chore: WIP}"
    run_cmd "git commit -m \"$msg\""
  else
    err "On s'arrête : arbre non propre."
    exit 1
  fi
  if ! check_clean_tree; then
    err "Toujours pas propre. Interruption."
    exit 1
  fi
  info "✅ Arbre propre."
}

# --- Normalisation & validation des noms de branche ---
normalize_branch_name() {
  local s="$1"
  s="${s//$'\r'/}"
  s="$(printf '%s' "$s" | sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//')"
  printf '%s' "$s"
}

branch_name_is_valid() {
  local name="$1"
  git check-ref-format --branch "$name" >/dev/null 2>&1
}

rebase_flow() {
  run_cmd "git fetch origin" || return $?
  if run_cmd "git rebase origin/main"; then
    info "Rebase terminé."
    return 0
  else
    warn "Conflits détectés pendant le rebase."
    warn "Résous les fichiers, puis : git add <fichiers> ; git rebase --continue"
    if confirm "Afficher git status ?" "y"; then run_cmd "git status"; fi
    if confirm "Tenter 'git rebase --continue' ?" "y"; then run_cmd "git rebase --continue"; fi
    return 0
  fi
}

final_verifications() {
  local BR="${1:-}"
  say "Vérifications finales — tout doit être à jour"
  run_cmd "git fetch origin"

  say "Check #1 : main local == origin/main"
  local lr
  lr="$(git rev-list --left-right --count main...origin/main || true)"
  info "rev-list: ${lr:-?}"
  if [ "${lr:-'X X'}" != $'0\t0' ] && [ "${lr:-'X X'}" != "0 0" ]; then
    err "❌ main local n'est pas aligné avec origin/main. Corrige : git pull --ff-only"
    return 1
  fi

  say "Check #2 : arbre de travail propre"
  if ! check_clean_tree; then
    err "❌ Modifs locales détectées. Nettoie/commit avant de conclure."
    return 1
  fi

  say "Check #3 : pas de diff main vs origin/main"
  if ! git diff --quiet origin/main..main; then
    err "❌ Diff détecté entre main et origin/main."
    return 1
  fi

  if [ -n "$BR" ]; then
    say "Check #4 : les changements de '$BR' sont intégrés dans origin/main"
    if git show-ref --verify --quiet "refs/remotes/origin/$BR"; then
      if git merge-base --is-ancestor "origin/$BR" "origin/main"; then
        info "OK (merge régulier)."
      else
        local plus_cnt
        plus_cnt="$(git cherry -v origin/main "origin/$BR" | awk '/^\+/{c++} END{print c+0}')"
        info "git cherry '+' restants : ${plus_cnt:-0}"
        if [ "${plus_cnt:-0}" -gt 0 ]; then
          err "❌ Des patchs de '$BR' ne sont pas dans origin/main (PR non mergée ?)."
          return 1
        else
          info "OK (intégré via squash/rebase)."
        fi
      fi
    else
      warn "Branche distante 'origin/$BR' introuvable (probablement supprimée après merge)."
      info "On continue."
    fi
  fi

  say "✅ Terminé : tout est à jour."
  return 0
}

print_pr_link() {
  local BR="$1"
  local origin_url
  origin_url="$(git remote get-url origin)"
  if [[ "$origin_url" =~ ^https://github.com/([^/]+)/([^/.]+)(\.git)?$ ]]; then
    local owner="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
    info "➡️  Ouvre/actualise ta PR : https://github.com/${owner}/${repo}/compare/main...${BR}?expand=1"
  else
    warn "Impossible de déduire l'URL PR depuis origin: $origin_url"
  fi
}

check_pages_cname() {
  if [ -f CNAME ]; then
    info "CNAME détecté à la racine : $(cat CNAME 2>/dev/null || true)"
  else
    warn "⚠️ Fichier CNAME manquant à la racine. Si tu utilises un domaine perso, pense à le créer."
  fi
}

# ============ Début du Wizard ============
ensure_git_repo
ensure_no_in_progress
validate_remote_origin

say "0) Pré-vol"
run_cmd "git rev-parse --abbrev-ref HEAD"
run_cmd "git remote -v"

say "1) Se caler sur main à jour"
run_cmd "git switch main"
assert_clean_tree_or_offer_fix
run_cmd "git fetch origin"
run_cmd "git pull --ff-only"

check_pages_cname

say "2) Créer (ou reprendre) la branche de travail"
BR=""
if confirm "Créer une nouvelle branche ?" "y"; then
  say "Création d'une nouvelle branche"
  while true; do
    printf "Nom de la branche (ex: feature/maj-menu-responsive) : "
    read -r BR || true
    BR="$(normalize_branch_name "${BR:-}")"
    if [ -z "${BR:-}" ]; then err "Entrée vide, réessaye."; continue; fi
    if branch_name_is_valid "$BR"; then
      break
    else
      err "Nom de branche invalide: '$BR'"
      warn "$(git check-ref-format --branch "$BR" 2>&1 || true)"
      warn "Rappels: pas d'espace, ni majuscule, ni '/' en tête/fin, ni '..', ni suffixe '.lock'."
    fi
  done
  if git show-ref --verify --quiet "refs/heads/$BR"; then
    warn "La branche existe déjà localement."
    run_cmd "git switch $BR"
  else
    run_cmd "git switch -c $BR"
  fi
else
  say "Reprendre une branche existante"
  while true; do
    printf "Nom de la branche à reprendre : "
    read -r BR || true
    BR="$(normalize_branch_name "${BR:-}")"
    if [ -z "${BR:-}" ]; then err "Entrée vide, réessaye."; continue; fi
    if branch_name_is_valid "$BR"; then
      break
    else
      err "Nom de branche invalide: '$BR'"
      warn "$(git check-ref-format --branch "$BR" 2>&1 || true)"
    fi
  done
  run_cmd "git switch $BR"
fi

say "3) Travaille dans ton éditeur. Quand prêt, on valide."
confirm "Passer au commit/push ?" "y" || { warn "OK, relance plus tard."; exit 0; }

say "4) Valider ton travail (commit & push)"
run_cmd "git add -A"
run_cmd "git status -sb"
if confirm "Faire le commit ?" "y"; then
  printf "Message de commit: "
  read -r MSG || true
  MSG="${MSG:-update}"
  run_cmd "git commit -m \"$MSG\""
fi

if confirm "Pousser la branche sur origin ?" "y"; then
  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    run_cmd "git push"
  else
    run_cmd "git push -u origin \"$BR\""
  fi
fi
print_pr_link "$BR"

say "5) Rebase sur origin/main avant PR (recommandé)"
run_cmd "git fetch origin"
if confirm "Rebase maintenant sur origin/main ?" "y"; then
  rebase_flow
  if confirm "Pousser les éventuels changements (post-rebase) ?" "y"; then
    run_cmd "git push --force-with-lease"
  fi
fi
print_pr_link "$BR"

say "6) Ouvrir/actualiser la PR sur GitHub, puis MERGE quand c'est prêt."
confirm "Confirme quand la PR est MERGÉE pour continuer." "y" || { warn "OK, relance après le merge."; exit 0; }

say "7) Synchroniser main local après merge"
run_cmd "git switch main"
run_cmd "git fetch origin"
run_cmd "git pull --ff-only"

say "8) Nettoyage de la branche de travail"
if confirm "Supprimer la branche LOCALE '$BR' ?" "y"; then
  run_cmd "git branch -d \"$BR\"" || warn "Suppression locale refusée (pas mergée ?)"
fi
if confirm "Supprimer la branche DISTANTE '$BR' ?" "y"; then
  run_cmd "git push origin --delete \"$BR\"" || warn "Suppression distante refusée."
fi

if final_verifications "$BR"; then
  exit 0
else
  err "❌ Les vérifications finales n'ont PAS toutes réussi. Corrige puis relance la fin."
  exit 1
fi
