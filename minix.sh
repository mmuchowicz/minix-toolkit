#!/bin/bash

######################################################
#
# Skrypt przygotowany do pracy z obrazem minixa
# oraz emulatorem qemu na laboratorium SOI
#
# Copyright 2015, Paweł Kubrak <peku33@gmail.com>
#
######################################################

set -u

# Katalog repozytorium, niezależny od katalogu, z którego wywołano skrypt
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Domyślne ustawienia. Mogą zostać nadpisane przez config/minix.conf
QEMU_CMD="${QEMU_CMD:-qemu-system-i386}"
QEMU_EXTRA_ARGS=(-display curses)
ZIP_CMD="${ZIP_CMD:-zip}"
MINIX_DATE_FORMAT="${MINIX_DATE_FORMAT:-+%Y_%m_%d_%H_%M_%S}"

MINIX_CUR_NAME="${MINIX_CUR_NAME:-minix203.img.cur}"
MINIX_SOURCE_IMAGE_NAME="${MINIX_SOURCE_IMAGE_NAME:-minix203.img.ori}"
MINIX_SOURCE_URL="${MINIX_SOURCE_URL:-http://www.ia.pw.edu.pl/~tkruk/edu/soi.b/lab/minix/minix203.img}"
MINIX_USR_LOCAL_DIR="${MINIX_USR_LOCAL_DIR:-minix_usr}"
MINIX_FILESYSTEM_TYPE="${MINIX_FILESYSTEM_TYPE:-minix}"
MINIX_PARTITION_OFFSET="${MINIX_PARTITION_OFFSET:-1483776}"
MINIX_DATA_DIR="${MINIX_DATA_DIR:-$SCRIPT_DIR}"
MINIX_BACKUP_DIR="${MINIX_BACKUP_DIR:-backups}"
MINIX_CONFIG_FILE="${MINIX_CONFIG_FILE:-$SCRIPT_DIR/config/minix.conf}"
if [[ "$MINIX_CONFIG_FILE" != /* ]]; then
    MINIX_CONFIG_FILE="$SCRIPT_DIR/$MINIX_CONFIG_FILE"
fi

if [[ -f "$MINIX_CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    if ! source "$MINIX_CONFIG_FILE"; then
        echo "Nie udało się wczytać konfiguracji: $MINIX_CONFIG_FILE" >&2
        exit 1
    fi
fi

# Katalogi względne w konfiguracji są interpretowane względem katalogu repozytorium
# Po przejściu do MINIX_DATA_DIR stare ścieżki względne zachowują dotychczasowe znaczenie
if [[ "$MINIX_DATA_DIR" != /* ]]; then
    MINIX_DATA_DIR="$SCRIPT_DIR/$MINIX_DATA_DIR"
fi
MINIX_AUTO_BACKUP_DIR="${MINIX_AUTO_BACKUP_DIR:-$MINIX_BACKUP_DIR/auto}"

print_help() {
    cat <<'HELP'
Dostępne polecenia

Użycie:
  ./minix.sh                    Uruchom menu
  ./minix.sh menu               Uruchom menu
  ./minix.sh help               Wyświetl dostępne polecenia
  ./minix.sh status             Pokaż stan środowiska i obrazów
  ./minix.sh start              Uruchom minixa w QEMU
  ./minix.sh backup [NAZWA]     Utwórz kopię; bez nazwy zapytaj interaktywnie
  ./minix.sh backup --auto      Utwórz kopię automatyczną
  ./minix.sh reset              Przywróć czysty obraz źródłowy (po potwierdzeniu)
  ./minix.sh restore [PLIK]     Przywróć kopię; bez pliku pokaż listę
  ./minix.sh export             Wyeksportuj zmienione pliki do archiwum
  ./minix.sh copy-image [CEL]   Skopiuj aktualny obraz na wskazany nośnik/ścieżkę

Uwagi:
  - Uruchomienie menu oraz operacje na obrazach wymagają praw administratora
  - Polecenia help i status nie wymagają praw administratora
  - Bez argumentów skrypt zachowuje dotychczasowe menu
HELP
}

die() {
    printf 'BŁĄD: %s\n' "$*" >&2
    return 1
}

require_root() {
    if (( EUID != 0 )); then
        die 'Ta operacja wymaga praw administratora. Uruchom skrypt przez sudo'
        return 1
    fi
}

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        die "Nie odnaleziono polecenia '$command_name'. Zainstaluj je i spróbuj ponownie"
        return 1
    fi
}

# Dane projektu są domyślnie przechowywane obok skryptu
prepare_data_directory() {
    mkdir -p -- "$MINIX_DATA_DIR" || {
        die "Nie można utworzyć katalogu danych: $MINIX_DATA_DIR"
        return 1
    }
    cd -- "$MINIX_DATA_DIR" || {
        die "Nie można przejść do katalogu danych: $MINIX_DATA_DIR"
        return 1
    }
    mkdir -p -- "$MINIX_USR_LOCAL_DIR" || {
        die "Nie można utworzyć punktu montowania: $MINIX_USR_LOCAL_DIR"
        return 1
    }
}

ensure_qemu() {
    require_command "$QEMU_CMD"
}

ensure_source_image() {
    if [[ -f "$MINIX_SOURCE_IMAGE_NAME" ]]; then
        return 0
    fi

# Sprawdź, czy istnieje obraz minixa, który posłuży jako źródło
    if ! command -v wget >/dev/null 2>&1; then
        die "Brak obrazu źródłowego '$MINIX_SOURCE_IMAGE_NAME' i polecenia wget"
        return 1
    fi

    echo "Brak domyślnego obrazu minixa ($MINIX_SOURCE_IMAGE_NAME), pobieram"
    while ! wget -O "$MINIX_SOURCE_IMAGE_NAME" "$MINIX_SOURCE_URL"; do
        echo 'Nie udało się pobrać obrazu minixa'
        read -r -p 'Naciśnij Enter, aby spróbować ponownie, lub Ctrl+C, aby przerwać'
    done
}

# Jeśli nie istnieje obraz roboczy - staje się nim oryginalny obraz minixa
ensure_working_image() {
    ensure_source_image || return 1
    if [[ ! -f "$MINIX_CUR_NAME" ]]; then
        cp -v -- "$MINIX_SOURCE_IMAGE_NAME" "$MINIX_CUR_NAME" || return 1
    fi
}

prepare_image_environment() {
    require_root || return 1
    prepare_data_directory || return 1
    ensure_working_image || return 1
}

image_is_mounted() {
    mount | grep -F -- "$PWD/$MINIX_CUR_NAME" >/dev/null 2>&1
}

# Uruchom minixa
run_minix() {
    ensure_qemu || return 1
    "$QEMU_CMD" "${QEMU_EXTRA_ARGS[@]}" -drive "format=raw,file=$MINIX_CUR_NAME"
}

# Backupuje aktualny obraz
# Tworzona jest kopia z nazwą podaną przez użytkownika
# shellcheck disable=SC2120
image_create_named_backup() {
	  local backup_name
	  # shellcheck disable=SC2034
	  backup_name="${1-}"

    mkdir -p -- "$MINIX_BACKUP_DIR" || return 1
    [[ -f "$MINIX_CUR_NAME" ]] || {
        die "Brak obrazu roboczego: $MINIX_CUR_NAME"
        return 1
    }
    if (( $# == 0 )); then
        read -r -p 'Wpisz nazwę kopii (nie podawaj nazwy, jeżeli chcesz, aby kopia miała automatycznie przydzielaną nazwę): ' backup_name
    fi

    if [[ -z "$backup_name" || "$backup_name" == '--auto' ]]; then
        image_create_backup
        return $?
    fi

    # Nazwa jest pojedynczym elementem ścieżki; nie pozwalamy na /, .. ani .
    if [[ "$backup_name" == */* || "$backup_name" == '.' || "$backup_name" == '..' ]]; then
        die 'Nieprawidłowa nazwa kopii. Podaj samą nazwę pliku, bez katalogów'
        return 1
    fi

    if [[ -e "$MINIX_BACKUP_DIR/$backup_name" ]]; then
        die "Kopia o nazwie '$backup_name' już istnieje"
        return 1
    fi

    cp -v -- "$MINIX_CUR_NAME" "$MINIX_BACKUP_DIR/$backup_name" || return 1
    echo "-> Utworzono kopię: $MINIX_BACKUP_DIR/$backup_name"
}

# Backupuje aktualny obraz
# Tworzona jest kopia z nazwą zawierającą aktualną datę
image_create_backup() {
    local backup_timestamp backup_filename backup_count oldest_backup

    mkdir -p -- "$MINIX_AUTO_BACKUP_DIR" || return 1
    [[ -f "$MINIX_CUR_NAME" ]] || {
        die "Brak obrazu roboczego: $MINIX_CUR_NAME"
        return 1
    }

    backup_timestamp="$(date "$MINIX_DATE_FORMAT")" || return 1
    backup_filename="$MINIX_AUTO_BACKUP_DIR/${MINIX_CUR_NAME}_${backup_timestamp}"
    local collision_suffix=1
    while [[ -e "$backup_filename" ]]; do
        backup_filename="$MINIX_AUTO_BACKUP_DIR/${MINIX_CUR_NAME}_${backup_timestamp}_${collision_suffix}"
        collision_suffix=$((collision_suffix + 1))
    done
    cp -v -- "$MINIX_CUR_NAME" "$backup_filename" || return 1

    backup_count="$(find "$MINIX_AUTO_BACKUP_DIR" -maxdepth 1 -type f | wc -l)"
    if (( backup_count > 5 )); then
        oldest_backup="$(find "$MINIX_AUTO_BACKUP_DIR" -maxdepth 1 -type f -printf '%f\n' | sort | head -n 1)"
        if [[ -n "$oldest_backup" ]]; then
            echo "-> Usunięto starą kopię zapasową: $MINIX_AUTO_BACKUP_DIR/$oldest_backup"
            rm -f -- "$MINIX_AUTO_BACKUP_DIR/$oldest_backup" || return 1
        fi
    fi
}

# Zamontuj obraz minixa w katalogu roboczym
# Działanie qemu kiedy obraz jest zamontowany jest (dla mnie) nieznane - po zmianach odmontowuję obraz
mount_image() {
    require_root || return 1
    if ! image_is_mounted; then
        mount -t "$MINIX_FILESYSTEM_TYPE" -o "loop,offset=$MINIX_PARTITION_OFFSET" \
            "$MINIX_CUR_NAME" "$MINIX_USR_LOCAL_DIR" || {
                die 'Nie udało się zamontować obrazu minixa. Sprawdź obsługę systemu plików i offset'
                return 1
            }
    fi
    echo "-> Minix został zamontowany w katalogu $MINIX_USR_LOCAL_DIR"
}

# Odmontowuje obraz
umount_image() {
    require_root || return 1
    if image_is_mounted; then
        while ! umount "$PWD/$MINIX_CUR_NAME"; do
            echo 'Nie udało się odmontować obrazu'
            read -r -p 'Zamknij procesy korzystające z minixa i naciśnij Enter, aby spróbować ponownie '
        done
    fi
    echo "-> Minix został odmontowany z katalogu $MINIX_USR_LOCAL_DIR"
}

ensure_image_mounted() {
    if ! image_is_mounted; then
        mount_image || return 1
    fi
}

action_start() {
    prepare_image_environment || return 1
    ensure_qemu || return 1
    ensure_image_mounted || return 1

    # Obraz musi być odmontowany na czas pracy emulatora
    umount_image || return 1
    image_create_backup || return 1

    echo '-> QEMU rozpoczyna pracę'
    local qemu_status=0
    run_minix || qemu_status=$?
    echo '-> QEMU kończy pracę'

    # Po QEMU obraz wraca do montowania
    mount_image || return 1
    return "$qemu_status"
}

# shellcheck disable=SC2120
action_backup() {
    local backup_name="${1-}"
    prepare_image_environment || return 1
    ensure_image_mounted || return 1
    umount_image || return 1

    if [[ "$backup_name" == '--auto' ]]; then
        image_create_backup
    elif (( $# > 0 )); then
        image_create_named_backup "$backup_name"
    else
        image_create_named_backup
    fi
    local backup_status=$?

    mount_image || return 1
    return "$backup_status"
}

# shellcheck disable=SC2120
action_reset() {
    local answer="${1-}"
    prepare_image_environment || return 1
    ensure_image_mounted || return 1

    if [[ -z "$answer" ]]; then
        read -r -p 'Czy na pewno zastąpić obraz roboczy czystym obrazem? [T/n]: ' answer
    fi
    if [[ ! "$answer" =~ ^([TtYy]|)$ ]]; then
        echo '-> Anulowano'
        return 0
    fi

    umount_image || return 1
    image_create_backup || return 1
    cp -v -- "$MINIX_SOURCE_IMAGE_NAME" "$MINIX_CUR_NAME" || return 1
    mount_image || return 1
    echo '-> Przywrócono czysty obraz minixa'
}

resolve_backup_path() {
    local backup_name="$1"

    if [[ -f "$backup_name" ]]; then
        printf '%s\n' "$backup_name"
    elif [[ -f "$MINIX_BACKUP_DIR/$backup_name" ]]; then
        printf '%s\n' "$MINIX_BACKUP_DIR/$backup_name"
    elif [[ -f "$MINIX_AUTO_BACKUP_DIR/$backup_name" ]]; then
        printf '%s\n' "$MINIX_AUTO_BACKUP_DIR/$backup_name"
    else
        return 1
    fi
}

# shellcheck disable=SC2120
action_restore() {
    local selected_backup="${1-}"
    local resolved_backup
    local -a available_backups=()

    prepare_image_environment || return 1
    ensure_image_mounted || return 1

    if [[ -n "$selected_backup" ]]; then
        resolved_backup="$(resolve_backup_path "$selected_backup")" || {
            die "Nie znaleziono kopii: $selected_backup"
            return 1
        }
    else
        mapfile -t available_backups < <(
            find "$MINIX_BACKUP_DIR" "$MINIX_AUTO_BACKUP_DIR" -maxdepth 1 -type f -print 2>/dev/null | sort
        )
        if (( ${#available_backups[@]} == 0 )); then
            die 'Brak kopii zapasowych do przywrócenia'
            return 1
        fi

        echo 'Dostępne kopie:'
        select resolved_backup in "${available_backups[@]}" 'Anuluj'; do
            if [[ "$resolved_backup" == 'Anuluj' || -z "$resolved_backup" ]]; then
                echo '-> Anulowano'
                return 0
            fi
            break
        done
    fi

    umount_image || return 1
    image_create_backup || return 1
    cp -v -- "$resolved_backup" "$MINIX_CUR_NAME" || return 1
    mount_image || return 1
    echo "-> Przywrócono kopię: $resolved_backup"
}

action_export() {
    local temp_mount_dir excludes files_diff zip_name

    prepare_image_environment || return 1
    require_command "$ZIP_CMD" || return 1
    ensure_image_mounted || return 1

    temp_mount_dir="$(mktemp -d)" || return 1
    if ! mount -t "$MINIX_FILESYSTEM_TYPE" \
        -o "loop,offset=$MINIX_PARTITION_OFFSET" \
        "$MINIX_SOURCE_IMAGE_NAME" "$temp_mount_dir"; then
        rmdir -- "$temp_mount_dir"
        die 'Nie udało się zamontować obrazu źródłowego do porównania'
        return 1
    fi

    excludes='/adm/|\.o$|\.pid$|/src/tools/'
    files_diff="$(
        {
            LANG=C diff -rqN "$MINIX_USR_LOCAL_DIR/" "$temp_mount_dir/" \
                | grep "^Only in $MINIX_USR_LOCAL_DIR" \
                | awk '{print $3 "/" $4}'
            LANG=C diff -rqN "$MINIX_USR_LOCAL_DIR/" "$temp_mount_dir/" \
                | grep '^Files' \
                | awk '{print $2}'
        } | grep -Ev "$excludes" || true
    )"

    if [[ -n "$files_diff" ]]; then
        zip_name="minix_diff_$(date "$MINIX_DATE_FORMAT").zip"
        # `zip -@` odczytuje listę plików z wejścia standardowego
        printf '%s\n' "$files_diff" | "$ZIP_CMD" "$zip_name" -@
        echo "-> Utworzono archiwum: $zip_name"
    else
        echo '-> Brak różnic'
    fi

    umount "$temp_mount_dir" || {
        die "Nie udało się odmontować katalogu tymczasowego: $temp_mount_dir"
        return 1
    }
    rmdir -- "$temp_mount_dir"
}

# shellcheck disable=SC2120
action_copy_image() {
    local destination="${1-}"
    local available_drives=()
    local selected_drive target_name

    prepare_image_environment || return 1
    [[ -f "$MINIX_CUR_NAME" ]] || {
        die "Brak obrazu roboczego: $MINIX_CUR_NAME"
        return 1
    }

    if [[ -n "$destination" ]]; then
        if [[ -d "$destination" ]]; then
            destination="$destination/minix203.img.final"
        fi
        cp -v -- "$MINIX_CUR_NAME" "$destination"
        return $?
    fi

    mapfile -t available_drives < <(mount | awk '$3 ~ /^\/media\// {print $3}')
    if (( ${#available_drives[@]} == 0 )); then
        die 'Nie znaleziono zamontowanych nośników w /media. Możesz podać ścieżkę docelową: copy-image /ścieżka/plik.img'
        return 1
    fi

    echo 'Wybierz nośnik docelowy:'
    select selected_drive in "${available_drives[@]}" 'Anuluj'; do
        if [[ "$selected_drive" == 'Anuluj' || -z "$selected_drive" ]]; then
            echo '-> Anulowano'
            return 0
        fi
        read -r -p 'Nazwa pliku [minix203.img.final]: ' target_name
        target_name="${target_name:-minix203.img.final}"
        cp -v -- "$MINIX_CUR_NAME" "$selected_drive/$target_name"
        return $?
    done
}

action_status() {
    local auto_backup_count=0 named_backup_count=0
    local qemu_state='niedostępne'
    local mount_state='niezamontowany'
    local auto_backup_dir="$MINIX_AUTO_BACKUP_DIR"
    local named_backup_dir="$MINIX_BACKUP_DIR"

    [[ "$auto_backup_dir" == /* ]] || auto_backup_dir="$MINIX_DATA_DIR/$auto_backup_dir"
    [[ "$named_backup_dir" == /* ]] || named_backup_dir="$MINIX_DATA_DIR/$named_backup_dir"

    if command -v "$QEMU_CMD" >/dev/null 2>&1; then
        qemu_state='dostępne'
    fi
    if mount | grep -F -- "$MINIX_DATA_DIR/$MINIX_CUR_NAME" >/dev/null 2>&1; then
        mount_state='zamontowany (według tabeli mount)'
    fi
    if [[ -d "$auto_backup_dir" ]]; then
        auto_backup_count="$(find "$auto_backup_dir" -maxdepth 1 -type f | wc -l)"
    fi
    if [[ -d "$named_backup_dir" ]]; then
        named_backup_count="$(find "$named_backup_dir" -maxdepth 1 -type f | wc -l)"
    fi

    printf '%-25s %s\n' 'Katalog danych:' "$MINIX_DATA_DIR"
    printf '%-25s %s\n' 'QEMU:' "$qemu_state"
    printf '%-25s %s\n' 'Obraz źródłowy:' "$([[ -f "$MINIX_DATA_DIR/$MINIX_SOURCE_IMAGE_NAME" ]] && echo 'istnieje' || echo 'brak')"
    printf '%-25s %s\n' 'Obraz roboczy:' "$([[ -f "$MINIX_DATA_DIR/$MINIX_CUR_NAME" ]] && echo 'istnieje' || echo 'brak')"
    printf '%-25s %s\n' 'Punkt montowania:' "$mount_state"
    printf '%-25s %s\n' 'Kopie automatyczne:' "$auto_backup_count"
    printf '%-25s %s\n' 'Kopie nazwane:' "$named_backup_count"
}

run_menu() {
    local choice answer

    prepare_image_environment || return 1
    ensure_qemu || return 1
    mount_image || return 1

    while true; do
    # Dopóki użytkownik nie wyjdzie z programu pokazujemy mu takie oto menu
        echo
        echo '==================================================='
        echo '== Wybierz polecenie:'
        echo '== 1) Uruchom minixa'
        echo '== 2) Stwórz backup obecnego obrazu'
        echo '== 3) Rozpocznij od czystego obrazu'
        echo '== 4) Przywróć poprzednią wersję'
        echo '== 5) Wyeksportuj zmienione pliki do archiwum'
        echo '== 6) Przenieś aktualny obraz na nośnik zewnętrzny'
        echo '== g) Uruchom gedit jako root'
        echo '== q) Zakończ pracę, idę spać.'
        read -r -p '== Wybór: ' choice
        echo '=================================================='

        case "$choice" in
            1) action_start ;;
            2) action_backup ;;
            3) action_reset ;;
            4) action_restore ;;
            5) action_export ;;
            6) action_copy_image ;;
            g|G)
                if command -v gedit >/dev/null 2>&1; then
                    gedit &
                    echo 'Uruchomiono gedit'
                else
                    echo 'Nie odnaleziono gedit' >&2
                fi
                ;;
            q|Q)
                echo '-> Zakończono'
                break
                ;;
            '')
                ;;
            *)
                echo 'Nieznana opcja. Wybierz pozycję z menu' >&2
                ;;
        esac
    done

    umount_image
}

main() {
    local command="${1:-menu}"

    case "$command" in
        help|-h|--help)
            print_help
            return 0
            ;;
        status)
            action_status
            return 0
            ;;
        menu)
            run_menu
            return $?
            ;;
        start)
            action_start
            return $?
            ;;
        backup)
            shift || true
            if (( $# > 1 )); then
                die 'Użycie: minix.sh backup [NAZWA|--auto]'
                return 2
            fi
            if (( $# == 0 )); then
                action_backup
            else
                action_backup "$1"
            fi
            return $?
            ;;
        reset)
            shift || true
            if (( $# > 1 )); then
                die 'Użycie: minix.sh reset [T|n]'
                return 2
            fi
            action_reset "${1-}"
            return $?
            ;;
        restore)
            shift || true
            if (( $# > 1 )); then
                die 'Użycie: minix.sh restore [PLIK_KOPII]'
                return 2
            fi
            action_restore "${1-}"
            return $?
            ;;
        export)
            shift || true
            if (( $# > 0 )); then
                die 'Użycie: minix.sh export'
                return 2
            fi
            action_export
            return $?
            ;;
        copy-image)
            shift || true
            if (( $# > 1 )); then
                die 'Użycie: minix.sh copy-image [ŚCIEŻKA_DOCELOWA]'
                return 2
            fi
            action_copy_image "${1-}"
            return $?
            ;;
        *)
            die "Nieznane polecenie: $command. Użyj './minix.sh help'"
            return 2
            ;;
    esac
}

main "$@"
