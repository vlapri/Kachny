#!/bin/bash

# Konfigurace
SCREEN_WIDTH=80
DUCK_WIDTH=15
MAX_POS=$((SCREEN_WIDTH - DUCK_WIDTH))
DIRECTION=1
POSITION=0
CURRENT_COLOR=33  # Žlutá
LAST_TEXT_CHANGE=0
TEXT_CHANGE_INTERVAL=5
TEXT_INDEX=0

# Pole zábavných textů pro bublinu
TEXTS=(
    "Quack! Jsem nejkrásnější kachna!"
    "Dneska je krásný den na plavání!"
    "Kde jsou moje kachňátka?"
    "Quack quack! Ahoj příteli!"
    "Miluji rybník v parku!"
    "Kdo má chuť na housky?"
    "Létání je super, ale plavání lepší!"
    "Quack! Vidíš moje peříčka?"
    "Dnes budu lovit ryby!"
    "Všichni milují kachny!"
)

# Funkce pro vymazání obrazovky
clear_screen() {
    clear
}

# Funkce pro kreslení kachny
draw_duck() {
    local pos=$1
    local color=$2
    
    # ASCII art kachny
    printf "%*s\e[${color}m \n" $pos ""
    #printf "%*s \n" $pos ""
    printf "%*s      ___\n" $pos ""
    printf "%*s     /   \\\\\n" $pos ""
    printf "%*s    | o o |\n" $pos ""
    printf "%*s     \\  -/\n" $pos ""
    printf "%*s      ---\n" $pos ""
    printf "%*s   __/   \\__\n" $pos ""
    printf "%*s  /         \\\\\n" $pos ""
    printf "%*s |  QUACK!   |\n" $pos ""
    printf "%*s  \\___   ___/\n" $pos ""
    printf "%*s      | |\n" $pos ""
    printf "%*s     _| |_\e[0m\n" $pos ""
}

# Funkce pro kreslení bubliny s textem
draw_bubble() {
    local pos=$1
    local text="$2"
    local text_len=${#text}
    local bubble_width=$((text_len + 4))
    local bubble_pos=$((pos + 8))
    
    # Horní část bubliny
    printf "%*s" $bubble_pos ""
    printf " "
    for ((i=0; i<bubble_width; i++)); do printf "_"; done
    printf "\n"
    
    # Střední část s textem
    printf "%*s< %s >\n" $bubble_pos "" "$text"
    
    # Spodní část bubliny
    printf "%*s" $bubble_pos ""
    printf " "
    for ((i=0; i<bubble_width; i++)); do printf "-"; done
    printf "\n"
    
    # Spojení s kachnou
    printf "%*s   \n" $bubble_pos ""
    printf "%*s    \n" $bubble_pos ""
}

# Funkce pro náhodnou barvu
get_random_color() {
    local colors=(31 32 33 34 35 36 91 92 93 94 95 96)
    echo ${colors[$((RANDOM % ${#colors[@]}))]}
}

# Funkce pro zpracování příkazů
process_command() {
    local cmd=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    
    case "$cmd" in
        "konec")
            echo "Nashledanou! Quack!"
            exit 0
            ;;
        "barva")
            CURRENT_COLOR=$(get_random_color)
            echo "Barva kachny změněna!"
            sleep 1
            ;;
        "")
            # Prázdný příkaz, nic nedělej
            ;;
        *)
            echo "Neznámý příkaz: $cmd"
            echo "Dostupné příkazy: konec, barva"
            sleep 2
            ;;
    esac
}

# Funkce pro aktualizaci pozice kachny
update_position() {
    POSITION=$((POSITION + DIRECTION))
    
    if [ $POSITION -le 0 ]; then
        POSITION=0
        DIRECTION=1
    elif [ $POSITION -ge $MAX_POS ]; then
        POSITION=$MAX_POS
        DIRECTION=-1
    fi
}

# Funkce pro aktualizaci textu v bublině
update_text() {
    local current_time=$(date +%s)
    
    if [ $((current_time - LAST_TEXT_CHANGE)) -ge $TEXT_CHANGE_INTERVAL ]; then
        TEXT_INDEX=$(((TEXT_INDEX + 1) % ${#TEXTS[@]}))
        LAST_TEXT_CHANGE=$current_time
    fi
}

# Hlavní smyčka
main_loop() {
    # Skrytí kurzoru
    tput civis
    
    # Zachycení signálu pro ukončení
    trap 'tput cnorm; clear; exit' INT TERM
    
    LAST_TEXT_CHANGE=$(date +%s)
    
    while true; do
        # Vymazání obrazovky
        clear_screen
        
        # Aktualizace textu
        update_text
        
        # Kreslení bubliny
        draw_bubble $POSITION "${TEXTS[$TEXT_INDEX]}"
        
        # Kreslení kachny
        draw_duck $POSITION $CURRENT_COLOR
        
        # Aktualizace pozice
        update_position
        
        # Oddělení od vstupu
        echo
        echo "=============================================="
        echo "Příkazy: 'konec' - ukončit, 'barva' - změnit barvu"
        echo "=============================================="
        
        # Vstupní řádek s timeoutem
        echo -n "Zadej příkaz: "
        
        # Čtení vstupu s timeoutem 0.3 sekundy
        if read -t 0.3 user_input; then
            process_command "$user_input"
        fi
        
        # Malá pauza pro plynulou animaci
        sleep 0.1
    done
}

# Úvodní zpráva
echo "=== ANIMOVANÁ KACHNA ==="
echo "Vítejte! Kachna bude chodit sem a tam."
echo "Můžete zadávat příkazy během animace."
echo "Pro spuštění stiskněte Enter..."
read

# Spuštění hlavní smyčky
main_loop
