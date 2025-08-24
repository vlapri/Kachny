#!/bin/bash

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

