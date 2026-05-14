{
    "control": [
        { "VTOY_DEFAULT_MENU_MODE": "0" },
        { "VTOY_LINUX_REMOUNT": "1" }
    ],
    "menu_class": [
        { "key": "Fedora", "class": "fedora" }
    ],
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
