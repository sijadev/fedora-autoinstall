{
    "auto_install": [
        {
            "image": "/FEDORA_ISO_FILENAME",
            "template": [
                {
                    "path": "/kickstart/fedora-full.ks",
                    "tip": "Vollstaendige Installation  (GNOME + NVIDIA + Podman + vLLM + Modelle)"
                },
                {
                    "path": "/kickstart/fedora-theme-bash.ks",
                    "tip": "Theme + Bash               (GNOME + WhiteSur + Oh-My-Bash, kein AI)"
                },
                {
                    "path": "/kickstart/fedora-headless-vllm.ks",
                    "tip": "Headless Podman + vLLM API (kein GUI, NVIDIA + Podman, vLLM als Dienst)"
                }
            ]
        }
    ]
}
