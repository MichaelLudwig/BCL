import streamlit as st

def main():
    # Seitenleiste für Navigation
    st.sidebar.title("Navigation")
    page = st.sidebar.radio("Gehe zu", ["Home", "Einstellungen"])

    # Hauptbereich
    st.title("Brandschutzconsult Reviewer")

    if page == "Home":
        st.write("Willkommen beim Brandschutzconsult Reviewer")
        
        # Eingabefeld für den Namen
        name = st.text_input("Name", "")
        
        if name:
            st.write(f"Hallo {name}!")

    elif page == "Einstellungen":
        st.write("Einstellungen")
        # Hier können später weitere Einstellungen hinzugefügt werden

if __name__ == "__main__":
    main() 