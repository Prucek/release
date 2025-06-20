#!/bin/bash

echo "Welcome to the Ultimate Productivity Booster!"
echo "Analyzing your motivation level..."
sleep 2

MOTIVATION=$((RANDOM % 3))

case $MOTIVATION in
    0)
        echo "Motivation level: LOW"
        echo "Suggestion: Take a coffee break ☕️"
        ;;
    1)
        echo "Motivation level: MEDIUM"
        echo "Suggestion: Watch a cat video 🐱"
        ;;
    2)
        echo "Motivation level: HIGH"
        echo "Suggestion: Keep coding like a rockstar! 🤘"
        ;;
esac

echo "Remember: Semicolons are not for winking ;) but for separating commands!"