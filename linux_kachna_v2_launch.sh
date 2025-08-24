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

# Import souboru s funkcemi
. ./linux_kachna_v2_func.sh

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
