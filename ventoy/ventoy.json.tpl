{
    "auto_install": [
        {
            "image": "/iso/NOBARA_ISO_FILENAME",
            "template": [
                {
                    "path": "/kickstart/nobara-full.ks",
                    "tip": "Vollstaendige Installation  (GNOME + NVIDIA + Podman + vLLM + Modelle)"
                },
                {
                    "path": "/kickstart/nobara-theme-bash.ks",
                    "tip": "Theme + Bash               (GNOME + WhiteSur + Oh-My-Bash, kein AI)"
                },
                {
                    "path": "/kickstart/nobara-headless-vllm.ks",
                    "tip": "Headless Podman + vLLM API (kein GUI, NVIDIA + Podman, vLLM als Dienst)"
                },
                {
                    "path": "/kickstart/nobara-vllm-only.ks",
                    "tip": "Nur vLLM direkt            (kein GUI, kein Podman, Python venv + vLLM API)"
                }
            ]
        }
    ]
}
